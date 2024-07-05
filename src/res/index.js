import { ChamberRenderer } from "./chamber_renderer.js";
import { makeChamber } from "./wasm.js";

function loadChamber(chamber, chamber_state) {
  const len = chamber_state.length;
  const chamber_save = chamber.instance.exports.saveMemory();
  const arr = new Uint8Array(
    chamber.instance.exports.memory.buffer,
    chamber_save,
    len,
  );
  arr.set(chamber_state);
  chamber.instance.exports.load();
}

class RemoteChamber {
  constructor(id, chamber, chamber_height) {
    this.chamber = chamber;

    const chambers = document.getElementById("chambers");
    this.canvas = new ChamberRenderer(chambers, chamber_height);
    this.chamber_pixel_len =
      this.canvas.canvas.width * this.canvas.canvas.height * 4;
    chamber.instance.exports.init(0, this.chamber_pixel_len);
    this.chamber_pixel_data = chamber.instance.exports.canvasMemory();
    this.id = id;

    this.render();
  }

  async render() {
    const simulation_response = await fetch("/simulation_state");
    const simulation_state = await simulation_response.json();

    loadChamber(this.chamber, simulation_state.chamber_states[this.id]);

    this.canvas.renderPopulatedChamber(
      simulation_state.chamber_balls[this.id],
      this.chamber,
    );
    window.setTimeout(() => this.render(), 16);
  }
}

class EmptyChamber {
  constructor(id, chamber_height) {
    const chambers = document.getElementById("chambers");
    this.canvas = new ChamberRenderer(chambers, chamber_height);
    this.id = id;

    this.render();
  }

  async render() {
    const simulation_response = await fetch("/simulation_state");
    const simulation_state = await simulation_response.json();

    this.canvas.renderEmptyChamber(simulation_state.chamber_balls[this.id]);
    window.setTimeout(() => this.render(), 16);
  }
}
async function init() {
  // FIXME: Do all requests at same time
  const num_chambers_resopnse = await fetch("/num_chambers");
  const num_chambers = await num_chambers_resopnse.json();

  const chamber_height_response = await fetch("/chamber_height");
  const chamber_height = await chamber_height_response.json();

  const chambers_per_row_response = await fetch("/chambers_per_row");
  const chambers_per_row = await chambers_per_row_response.json();

  const num_balls_response = await fetch("/num_balls");
  const num_balls = await num_balls_response.json();

  const num_balls_spinner = document.getElementById("num_balls");
  num_balls_spinner.value = num_balls;
  num_balls_spinner.onchange = (ev) => {
    const req = new Request("/num_balls", {
      method: "PUT",
      body: ev.target.value.toString(),
    });
    fetch(req);
  };

  let i = 0;
  for (; i < num_chambers; ++i) {
    const obj = await makeChamber("/" + i + "/chamber.wasm");
    new RemoteChamber(i, obj, chamber_height);
  }

  const end_empty_chambers =
    num_chambers +
    ((chambers_per_row - (num_chambers % chambers_per_row)) % chambers_per_row);
  for (; i < end_empty_chambers; ++i) {
    new EmptyChamber(i, chamber_height);
  }

  const reset_button = document.getElementById("reset");
  reset_button.onclick = () => fetch("/reset");

  const userinfo_response = await fetch("/userinfo");
  const userinfo = await userinfo_response.json();
  if (userinfo.match(/^[0-9a-zA-Z]{1,16}$/)) {
    document.getElementById("username").innerHTML = "hello " + userinfo;
  } else {
    document.getElementById("username").innerHTML = "hello <REDACTED>";
  }
}

window.onload = init;
