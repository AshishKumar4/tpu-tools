import jax
import jax.numpy as jnp

from jax.sharding import Mesh, PartitionSpec as P, NamedSharding
from jax.experimental.shard_map import shard_map
from jax.experimental.multihost_utils import process_allgather
import flax
import jax.tree_util as jtu
import numpy as np
from functools import partial
from flax import struct          
from flax.training import train_state
import optax

jax.distributed.initialize()

def _build_global_shape_and_sharding(
    local_shape: tuple[int, ...], global_mesh: Mesh
) -> tuple[tuple[int, ...], NamedSharding]:
  sharding = NamedSharding(global_mesh, P(global_mesh.axis_names))
  global_shape = (jax.process_count() * local_shape[0],) + local_shape[1:]
  return global_shape, sharding

def form_global_array(path, array: np.ndarray, global_mesh: Mesh) -> jax.Array:
  """Put local sharded array into local devices"""
  global_shape, sharding = _build_global_shape_and_sharding(np.shape(array), global_mesh)
  try:
    local_device_arrays = np.split(array, len(global_mesh.local_devices), axis=0)
  except ValueError as array_split_error:
    raise ValueError(
        f"Unable to put to devices shape {array.shape} with "
        f"local device count {len(global_mesh.local_devices)} "
        f"at {jtu.keystr(path)}"
    ) from array_split_error
  local_device_buffers = jax.device_put(local_device_arrays, global_mesh.local_devices)
  return jax.make_array_from_single_device_arrays(global_shape, sharding, local_device_buffers)

def convert_to_global_tree(global_mesh, pytree):
    return jax.tree_util.tree_map_with_path(partial(form_global_array, global_mesh=global_mesh), pytree)

class RandomMarkovState(struct.PyTreeNode):
    rng: jax.random.PRNGKey
    def get_random_key(self):
        rng, subkey = jax.random.split(self.rng)
        return RandomMarkovState(rng), subkey

# Define the TrainState
class TrainState(train_state.TrainState):
    pass

index = jax.process_index()
print("Current process index")

def func(x, rngs, state:TrainState, local_device_index):
    # rngs = RandomMarkovState(rngs.rng.reshape((2,)))
    rngs, subkey = rngs.get_random_key()
    subkey = jax.random.fold_in(subkey, local_device_index.reshape())
    return jax.lax.psum(x, 'i'), rngs, state, subkey

rngs = RandomMarkovState(jax.random.PRNGKey(0))

sample_params = {'params': {'dense': {'kernel': jnp.ones((1, 1)), 'bias': jnp.zeros((1,))}}}
print("Sample params:", sample_params)

state = TrainState.create(
    apply_fn=lambda : None,
    params=sample_params,
    tx=optax.adam(1e-3),
)

mesh = jax.sharding.Mesh(jax.devices(), 'i')

data = jnp.arange(16).reshape((16, 1))
if jax.process_index() == 0:
  data = data ** 2

data = convert_to_global_tree(mesh, data)
print("Input data: ", jax.experimental.multihost_utils.process_allgather(data), jax.debug.visualize_array_sharding(data))
local_device_indexes = jnp.arange(jax.device_count())
# local_device_indexes = convert_to_global_tree(mesh, local_device_indexes)
loss, rngs, state, subkey = jax.jit(shard_map(func, mesh=mesh, in_specs=(P('i'), P(), P(), P('i')), out_specs=(P(), P(), P(), P('i'))))(data, rngs, state, local_device_indexes)

print("Output Shard map:", jax.experimental.multihost_utils.process_allgather(loss), jax.debug.visualize_array_sharding(loss))
print("Subkeys: ", jax.experimental.multihost_utils.process_allgather(subkey), jax.debug.visualize_array_sharding(subkey))