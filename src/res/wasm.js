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
  initChamber(max_balls) {
    this.chamber.instance.exports.init(max_balls, 600 * 450);
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
      logWasm: logWasm.bind(callbacks.simulation),
    },
  };

  const simulation = await WebAssembly.instantiateStreaming(
    fetch("/simulation.wasm"),
    simulationImport,
  );
  callbacks.simulation = simulation;

  return simulation;
}
