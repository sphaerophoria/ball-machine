import { canvas_width } from "./chamber_renderer.js";
import { LocalSimulation, SplitLocalSimulation } from "./local_simulation.js";
import { makeChamberDirect, makeSimulation } from "./wasm.js";

var simulation_widget = null;
var num_balls_spinner = null;
var speed_slider = null;
var save_load_checkmark = null;

async function loadChamber() {
  const parent = document.getElementById("demo");
  parent.innerHTML = "";

  const update_div = document.createElement("div");
  update_div.innerHTML = "Last update: " + new Date();
  parent.appendChild(update_div);

  try {
    if (simulation_widget !== null) {
      simulation_widget.shutdown = true;
    }

    const file_input = document.getElementById("wasm_input");
    const buffer = await file_input.files[0].arrayBuffer();
    const chamber = await makeChamberDirect(buffer);
    const simulation = await makeSimulation(chamber);
    simulation.instance.exports.init(
      0,
      canvas_width * canvas_width * simulation.instance.exports.chamberHeight(),
    );
    num_balls_spinner.value = simulation.instance.exports.numBalls();
    speed_slider.value = 100;

    if (save_load_checkmark.checked === true) {
      const render_chamber = await makeChamberDirect(buffer);
      render_chamber.instance.exports.init(
        0,
        canvas_width *
          canvas_width *
          simulation.instance.exports.chamberHeight(),
      );
      simulation_widget = new SplitLocalSimulation(
        parent,
        chamber,
        render_chamber,
        simulation,
      );
    } else {
      simulation_widget = new LocalSimulation(parent, chamber, simulation);
    }
  } catch (e) {
    const error_div = document.createElement("div");
    error_div.innerHTML = e;
    parent.appendChild(error_div);
  }
}

async function init() {
  let wasm_input = document.getElementById("wasm_input");
  num_balls_spinner = document.getElementById("num_balls");
  speed_slider = document.getElementById("speed");

  save_load_checkmark = document.getElementById("save_load");
  save_load_checkmark.addEventListener("change", async () => {
    loadChamber();
  });

  wasm_input.addEventListener("change", async () => {
    loadChamber();
  });

  num_balls_spinner.onchange = (ev) => {
    simulation_widget.simulation.instance.exports.setNumBalls(ev.target.value);
  };

  const reset_button = document.getElementById("reset");
  reset_button.onclick = () =>
    simulation_widget.simulation.instance.exports.reset();

  speed_slider.onchange = (ev) => {
    simulation_widget.simulation.instance.exports.setSpeed(
      ev.target.value / 100.0,
    );
  };
}

window.onload = init;
