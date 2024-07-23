import {
  renderChamberIntoCanvas,
  canvas_width,
  renderBallsIntoCanvas,
} from "./chamber_renderer.js";

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

export class ChamberRenderer {
  constructor(parent, chamber_height) {
    this.canvas = document.createElement("canvas");
    parent.appendChild(this.canvas);

    this.canvas.width = canvas_width;
    this.canvas.height = this.canvas.width * chamber_height;
  }

  makeBounds() {
    return {
      x: 0,
      y: 0,
      width: Math.floor(this.canvas.width),
      height: Math.floor(this.canvas.height),
    };
  }

  renderBalls(balls) {
    renderBallsIntoCanvas(balls, this.canvas, this.makeBounds());
  }

  renderChamber(chamber) {
    renderChamberIntoCanvas(chamber, this.canvas, this.makeBounds());
  }

  render(balls, chamber) {
    this.renderChamber(chamber);
    this.renderBalls(balls);
  }
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

    this.canvas.render(getBalls(this.simulation), this.chamber);
    window.setTimeout(() => this.render(), 16);
  }
}

export class SplitLocalSimulation {
  constructor(parent, physics_chamber, render_chamber, simulation) {
    this.physics_chamber = physics_chamber;
    this.render_chamber = render_chamber;
    this.simulation = simulation;

    this.canvas = new ChamberRenderer(
      parent,
      this.simulation.instance.exports.chamberHeight(),
    );
    this.chamber_pixel_len =
      this.canvas.canvas.width * this.canvas.canvas.height * 4;
    this.chamber_pixel_data = render_chamber.instance.exports.canvasMemory();

    this.start = Date.now();
    this.render();
  }

  async render() {
    if (this.shutdown === true) {
      return;
    }

    const elapsed = (Date.now() - this.start) / 1000;
    this.simulation.instance.exports.stepUntil(elapsed);

    this.physics_chamber.instance.exports.save();
    const physics_save = new Uint8Array(
      this.physics_chamber.instance.exports.memory.buffer,
      this.physics_chamber.instance.exports.saveMemory(),
      this.physics_chamber.instance.exports.saveSize(),
    );
    const render_save = new Uint8Array(
      this.render_chamber.instance.exports.memory.buffer,
      this.render_chamber.instance.exports.saveMemory(),
      this.render_chamber.instance.exports.saveSize(),
    );
    render_save.set(physics_save);
    this.render_chamber.instance.exports.load();

    this.canvas.render(getBalls(this.simulation), this.render_chamber);
    window.setTimeout(() => this.render(), 16);
  }
}
