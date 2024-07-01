import { SimulationRenderer } from "./simulation_renderer.js";
import { makeChamber } from "./wasm.js";

function loadChamber(chamber, simulation_state) {
  const len = simulation_state.chamber_state.length;
  const chamber_save = chamber.instance.exports.saveMemory();
  const arr = new Uint8Array(
    chamber.instance.exports.memory.buffer,
    chamber_save,
    len,
  );
  arr.set(simulation_state.chamber_state);
  chamber.instance.exports.load();
}

class RemoteSimulation {
  constructor(id, chamber) {
    this.chamber = chamber;

    this.canvas = new SimulationRenderer(document.body);
    this.chamber_pixel_len =
      this.canvas.canvas.width * this.canvas.canvas.height * 4;
    chamber.instance.exports.init(0, this.chamber_pixel_len);
    this.chamber_pixel_data = chamber.instance.exports.canvasMemory();
    this.prefix = "/" + id;

    this.canvas.button.onclick = () => fetch(this.prefix + "/save");
    this.canvas.reset_button.onclick = () => fetch(this.prefix + "/reset");

    this.render();
  }

  async render() {
    const simulation_response = await fetch(this.prefix + "/simulation_state");
    const simulation_state = await simulation_response.json();

    loadChamber(this.chamber, simulation_state);

    this.canvas.render(simulation_state.balls, this.chamber);
    window.setTimeout(() => this.render(), 16);
  }
}

async function init() {
  const num_sims_response = await fetch("/num_simulations");
  const num_simulations = await num_sims_response.json();

  for (let i = 0; i < num_simulations; ++i) {
    const obj = await makeChamber("/" + i + "/chamber.wasm");
    new RemoteSimulation(i, obj);
  }

  const userinfo_response = await fetch("/userinfo");
  const userinfo = await userinfo_response.json();
  if (userinfo.match(/^[0-9a-zA-Z]{1,16}$/)) {
    document.getElementById("username").innerHTML = "hello " + userinfo;
  } else {
    document.getElementById("username").innerHTML = "hello <REDACTED>";
  }
}

window.onload = init;
