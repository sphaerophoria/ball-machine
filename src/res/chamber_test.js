import { SimulationRenderer } from "./simulation_renderer.js";
import { makeChamberDirect, makeSimulation } from "./wasm.js";

var simulation_widget = null;

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
  constructor(parent, chamber, simulation) {
    this.chamber = chamber;
    this.simulation = simulation;

    this.canvas = new SimulationRenderer(parent);
    this.chamber_pixel_len =
      this.canvas.canvas.width * this.canvas.canvas.height * 4;
    this.chamber_pixel_data = chamber.instance.exports.canvasMemory();

    //this.canvas.button.onclick = () => fetch(this.prefix + "/save");
    this.canvas.reset_button.onclick = () =>
      this.simulation.instance.exports.reset();

    this.start = Date.now();
    this.render();
  }

  async render() {
    if (this.shutdown === true) {
      return;
    }

    const elapsed = (Date.now() - this.start) / 1000;
    this.simulation.instance.exports.step_until(elapsed);

    this.canvas.render(getBalls(this.simulation), this.chamber);
    window.setTimeout(() => this.render(), 16);
  }
}

async function init() {
  window.ondrop = async (ev) => {
    ev.preventDefault();
    const parent = document.getElementById("demo");
    parent.innerHTML = "";

    const update_div = document.createElement("div");
    update_div.innerHTML = "Last update: " + new Date();
    parent.appendChild(update_div);

    try {
      if (simulation_widget !== null) {
        simulation_widget.shutdown = true;
      }

      const buffer = await ev.dataTransfer.files[0].arrayBuffer();
      const chamber = await makeChamberDirect(buffer);
      const simulation = await makeSimulation(chamber);
      simulation.instance.exports.init();

      simulation_widget = new LocalSimulation(parent, chamber, simulation);
    } catch (e) {
      const error_div = document.createElement("div");
      error_div.innerHTML = e;
      parent.appendChild(error_div);
    }
  };

  window.ondragover = (ev) => {
    ev.preventDefault();
  };
}

window.onload = init;
