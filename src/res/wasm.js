function logWasm(module, s, len) {
  var uint_arr = new Uint8Array(module.instance.exports.memory.buffer, s, len);
  var dec = new TextDecoder();
  const str = dec.decode(uint_arr);
  console.log(str);
}

export async function makeChamber(url) {
  const chamber = {};
  const chamberImport = {
    env: { logWasm: (...args) => logWasm(chamber.item, ...args) },
  };

  chamber.item = await WebAssembly.instantiateStreaming(
    fetch(url),
    chamberImport,
  );

  return chamber.item;
}

export async function makeChamberDirect(buffer) {
  const chamber = {};
  const chamberImport = {
    env: { logWasm: (...args) => logWasm(chamber.item, ...args) },
  };

  chamber.item = await WebAssembly.instantiate(buffer, chamberImport);

  return chamber.item;
}

class SimulationCallbacks {
  initChamber(max_balls, canvas_max_pixels) {
    this.chamber.instance.exports.init(max_balls, canvas_max_pixels);
    return true;
  }

  stepChamber(balls_ptr, byte_len, num_balls, delta) {
    let sim_balls = new Uint8Array(
      this.simulation.instance.exports.memory.buffer,
      balls_ptr,
      byte_len,
    );

    let chamber_dest = this.chamber.instance.exports.ballsMemory();
    let chamber_balls = new Uint8Array(
      this.chamber.instance.exports.memory.buffer,
      chamber_dest,
      byte_len,
    );

    chamber_balls.set(sim_balls);

    this.chamber.instance.exports.step(num_balls, delta);

    // If realloc causes wasm memory to grow, the buffer is in a new location and we need to look again
    chamber_balls = new Uint8Array(
      this.chamber.instance.exports.memory.buffer,
      chamber_dest,
      byte_len,
    );

    sim_balls.set(chamber_balls);
  }
}

export async function makeSimulation(chamber) {
  const callbacks = new SimulationCallbacks();
  callbacks.chamber = chamber;

  const simulationImport = {
    env: {
      initChamber: callbacks.initChamber.bind(callbacks),
      stepChamber: callbacks.stepChamber.bind(callbacks),
      logWasm: (...args) => logWasm(callbacks.simulation, ...args),
    },
  };

  const simulation = await WebAssembly.instantiateStreaming(
    fetch("/simulation.wasm"),
    simulationImport,
  );
  callbacks.simulation = simulation;

  return simulation;
}
