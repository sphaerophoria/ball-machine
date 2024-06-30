import { SimulationRenderer } from "./simulation_renderer.js";
import { makeChamber, makeSimulation } from "./wasm.js";

function getBalls(simulation) {
  const state_ptr = simulation.instance.exports.state();
  const state_arr = new Uint8Array(
    simulation.instance.exports.memory.buffer,
    state_ptr,
    4096,
  );

  const js_len = state_arr.indexOf(0);
  var dec = new TextDecoder();
  const str = dec.decode(state_arr.slice(0, js_len));
  return JSON.parse(str);
}

class LocalSimulation {
  constructor(chamber, simulation) {
    this.chamber = chamber;
    this.simulation = simulation;

    this.canvas = new SimulationRenderer();
    this.chamber_pixel_len =
      this.canvas.canvas.width * this.canvas.canvas.height * 4;
    this.chamber_pixel_data = chamber.instance.exports.canvasMemory();

    //this.canvas.button.onclick = () => fetch(this.prefix + "/save");
    this.canvas.reset_button.onclick = () =>
      this.simulation.instance.exports.reset();

    this.render();
  }

  async render() {
    for (let i = 0; i < 10; i++) {
      this.simulation.instance.exports.step();
    }

    this.canvas.render(getBalls(this.simulation), this.chamber);
    window.setTimeout(() => this.render(), 16);
  }
}

async function init() {
  const chamber = await makeChamber("/platforms.wasm");
  const simulation = await makeSimulation(chamber);

  simulation.instance.exports.init();

  new LocalSimulation(chamber, simulation);
}

window.onload = init;
