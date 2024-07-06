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
  constructor(parent, id, chamber, chamber_height) {
    this.chamber = chamber;

    this.canvas = new ChamberRenderer(parent, chamber_height);
    this.chamber_pixel_len =
      this.canvas.canvas.width * this.canvas.canvas.height * 4;
    chamber.instance.exports.init(0, this.chamber_pixel_len);
    this.chamber_pixel_data = chamber.instance.exports.canvasMemory();
    this.id = id;
  }

  async render(simulation_state) {
    loadChamber(this.chamber, simulation_state.chamber_states[this.id]);

    this.canvas.renderPopulatedChamber(
      simulation_state.chamber_balls[this.id],
      this.chamber,
    );
  }
}

class EmptyChamber {
  constructor(parent, id, chamber_height) {
    this.canvas = new ChamberRenderer(parent, chamber_height);
    this.id = id;
  }

  async render(simulation_state) {
    try {
      this.canvas.renderEmptyChamber(simulation_state.chamber_balls[this.id]);
    } catch (e) {}
  }
}

let relayout_queue = Promise.resolve();

class ChamberRegistry {
  constructor(parent, chamber_ids, chambers_per_row, chamber_height) {
    this.parent = parent;
    this.chambers = [];
    this.chamber_height = chamber_height;
    this.relayout(chamber_ids, chambers_per_row);
    this.render();
  }

  async relayout(chamber_ids, chambers_per_row) {
    this.parent.innerHTML = "";
    this.chambers = [];

    let i = 0;
    for (; i < chamber_ids.length; ++i) {
      const obj = await makeChamber("/" + chamber_ids[i] + "/chamber.wasm");
      this.chambers.push(
        new RemoteChamber(this.parent, i, obj, this.chamber_height),
      );
    }

    const end_empty_chambers =
      chamber_ids.length +
      ((chambers_per_row - (chamber_ids.length % chambers_per_row)) %
        chambers_per_row);
    for (; i < end_empty_chambers; ++i) {
      this.chambers.push(new EmptyChamber(this.parent, i, this.chamber_height));
    }
  }

  async render() {
    const simulation_response = await fetch("/simulation_state");
    const simulation_state = await simulation_response.json();

    for (const chamber of this.chambers) {
      chamber.render(simulation_state);
    }
    window.setTimeout(() => this.render(), 16);
  }
}

async function init() {
  // FIXME: Do all requests at same time
  const init_info_response = await fetch("/init_info");
  const init_info = await init_info_response.json();

  const chamber_height = init_info.chamber_height;
  const chambers_per_row = init_info.chambers_per_row;
  const num_balls = init_info.num_balls;
  const chamber_ids = init_info.chamber_ids;

  const chambers_div = document.getElementById("chambers");
  const registry = new ChamberRegistry(
    chambers_div,
    chamber_ids,
    chambers_per_row,
    chamber_height,
  );

  const num_balls_spinner = document.getElementById("num_balls");
  num_balls_spinner.value = num_balls;
  num_balls_spinner.onchange = (ev) => {
    const req = new Request("/num_balls", {
      method: "PUT",
      body: ev.target.value.toString(),
    });
    fetch(req);
  };

  const style = document.querySelector("#chambers");
  style.style.setProperty("--num-columns", chambers_per_row);

  const chambers_per_row_spinner = document.getElementById("chambers_per_row");
  chambers_per_row_spinner.value = chambers_per_row;
  chambers_per_row_spinner.onchange = (ev) => {
    relayout_queue = relayout_queue.then(async () => {
      try {
        const req = new Request("/chambers_per_row", {
          method: "PUT",
          body: ev.target.value.toString(),
        });
        await fetch(req);
        await registry.relayout(chamber_ids, ev.target.value);
        style.style.setProperty("--num-columns", ev.target.value);
      } catch (e) {}
    });
  };

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
