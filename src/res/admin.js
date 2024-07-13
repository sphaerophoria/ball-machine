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
    " by " +
    sanitize(chamber.user) +
    "</h3>";

  const canvas_holder = document.createElement("div");
  chamber_div.append(canvas_holder);

  const chamber_id = chamber.chamber_id;
  const sim = await instantiateChamber(canvas_holder, chamber_id);
  const accept = document.createElement("button");
  accept.innerHTML = "accept";

  /* jshint ignore:start */
  accept.onclick = async () => {
    await fetch("/accept_chamber?id=" + chamber_id);
    sim.shutdown = true;
    document.body.removeChild(chamber_div);
  };
  /* jshint ignore:end */

  chamber_div.append(accept);

  const reject = document.createElement("button");
  reject.innerHTML = "reject";

  /* jshint ignore:start */
  reject.onclick = async () => {
    await fetch("/reject_chamber?id=" + chamber_id);
    sim.shutdown = true;
    document.body.removeChild(chamber_div);
  };
  /* jshint ignore:end */
  chamber_div.append(reject);

  document.body.appendChild(chamber_div);
}

async function init() {
  const chambers_resopnse = await fetch("/unaccepted_chambers");
  const chambers = await chambers_resopnse.json();

  for (const chamber of chambers) {
    makeChamberWidget(chamber);
  }
}

window.onload = init;
