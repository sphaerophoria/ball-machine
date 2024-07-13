import { canvas_width } from "./chamber_renderer.js";
import { LocalSimulation } from "./local_simulation.js";
import { makeChamber, makeSimulation } from "./wasm.js";
import { sanitize } from "./sanitize.js";

async function instantiateChamber(parent, id) {
  const chamber = await makeChamber("/" + id + "/chamber.wasm");
  const simulation = await makeSimulation(chamber);
  simulation.instance.exports.init(
    0,
    canvas_width * canvas_width * simulation.instance.exports.chamberHeight(),
  );
  return new LocalSimulation(parent, chamber, simulation);
}

async function makeChamberWidget(chamber) {
  const chamber_div = document.createElement("div");
  chamber_div.innerHTML =
    "<h3>" +
    sanitize(chamber.chamber_name) +
    ": " +
    sanitize(chamber.state) +
    "</h3>";

  const canvas_holder = document.createElement("div");
  chamber_div.append(canvas_holder);

  const chamber_id = chamber.chamber_id;
  await instantiateChamber(canvas_holder, chamber_id);

  chamber_div.append(chamber.message);

  document.body.appendChild(chamber_div);
}

async function init() {
  const my_chambers_response = await fetch("/my_chambers");
  const my_chambers = await my_chambers_response.json();

  for (const chamber of my_chambers) {
    makeChamberWidget(chamber);
  }
}

window.onload = init;
