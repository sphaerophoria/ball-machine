import { ChamberRenderer } from "./chamber_renderer.js";
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

    this.canvas = new ChamberRenderer(
      parent,
      this.simulation.instance.exports.chamberHeight(),
    );
    this.chamber_pixel_len =
      this.canvas.canvas.width * this.canvas.canvas.height * 4;
    this.chamber_pixel_data = chamber.instance.exports.canvasMemory();

    this.start = Date.now();
    this.render();
  }

  async render() {
    if (this.shutdown === true) {
      return;
    }

    const elapsed = (Date.now() - this.start) / 1000;
    this.simulation.instance.exports.stepUntil(elapsed);

    this.canvas.renderPopulatedChamber(getBalls(this.simulation), this.chamber);
    window.setTimeout(() => this.render(), 16);
  }
}

async function init() {
  let wasm_input = document.getElementById("wasm_input");
  const num_balls_spinner = document.getElementById("num_balls");

  wasm_input.addEventListener("change", async (ev) => {
    const parent = document.getElementById("demo");
    parent.innerHTML = "";

    const update_div = document.createElement("div");
    update_div.innerHTML = "Last update: " + new Date();
    parent.appendChild(update_div);

    try {
      if (simulation_widget !== null) {
        simulation_widget.shutdown = true;
      }

      const buffer = await ev.target.files[0].arrayBuffer();
      const chamber = await makeChamberDirect(buffer);
      const simulation = await makeSimulation(chamber);
      simulation.instance.exports.init();
      num_balls_spinner.value = simulation.instance.exports.numBalls();

      simulation_widget = new LocalSimulation(parent, chamber, simulation);
    } catch (e) {
      const error_div = document.createElement("div");
      error_div.innerHTML = e;
      parent.appendChild(error_div);
    }
  });

  num_balls_spinner.onchange = (ev) => {
    simulation_widget.simulation.instance.exports.setNumBalls(ev.target.value);
  };

  const reset_button = document.getElementById("reset");
  reset_button.onclick = () =>
    simulation_widget.simulation.instance.exports.reset();
}

window.onload = init;
