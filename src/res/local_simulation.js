import { ChamberRenderer } from "./chamber_renderer.js";

function getBalls(simulation) {
  const state_ptr = simulation.instance.exports.state();
  const state_arr = new Uint8Array(
    simulation.instance.exports.memory.buffer,
    state_ptr,
    16384,
  );

  const js_len = state_arr.indexOf(0);
  var dec = new TextDecoder();
  const str = dec.decode(state_arr.slice(0, js_len));
  return JSON.parse(str);
}

export class LocalSimulation {
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
