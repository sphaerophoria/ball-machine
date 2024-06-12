var num_simulations = null;

const id = "/1";

function wasmLog(s, len) {
  // Unimplemented, need a way to figure out which memory to read from
  //
  //var uint_arr = new Uint8Array(chamber.instance.exports.memory.buffer, s, len);
  //var dec = new TextDecoder();
  //const str = dec.decode(uint_arr);
  //console.log(str);
}

function getChamberPixels(chamber, chamber_pixel_data, chamber_pixel_len) {
  return new Uint8ClampedArray(
    chamber.instance.exports.memory.buffer,
    chamber_pixel_data,
    chamber_pixel_len,
  );
}

function loadChamber(chamber, simulation_state) {
  const len = simulation_state.chamber_state.length;
  const chamber_save = chamber.instance.exports.alloc(len, 1);
  const arr = new Uint8Array(
    chamber.instance.exports.memory.buffer,
    chamber_save,
    len,
  );
  arr.set(simulation_state.chamber_state);

  const chamber_state = chamber.instance.exports.load(chamber_save);
  chamber.instance.exports.free(chamber_save);
  return chamber_state;
}

class Chamber {
  constructor(id, chamber) {
    this.prefix = "/" + id;
    this.chamber = chamber;

    const top_div = document.createElement("div");
    const canvas_div = document.createElement("div");
    top_div.append(canvas_div);

    this.canvas = document.createElement("canvas");
    canvas_div.appendChild(this.canvas);

    this.canvas.width = 800;
    this.canvas.height = 600;

    const button_div = document.createElement("div");
    top_div.append(button_div);

    const button = document.createElement("button");
    button_div.append(button);

    button.innerHTML = "Save history";
    button.onclick = () => fetch(this.prefix + "/save");

    const reset_button = document.createElement("button");
    button_div.append(reset_button);

    reset_button.innerHTML = "Reset";
    reset_button.onclick = () => fetch(this.prefix + "/reset");

    document.body.appendChild(top_div);

    this.chamber_pixel_len = this.canvas.width * this.canvas.height * 4;
    this.chamber_pixel_data = chamber.instance.exports.alloc(
      this.chamber_pixel_len,
      4,
    );
    this.render();
  }

  async render() {
    /** @type HTMLCanvasElement */
    var ctx = this.canvas.getContext("2d");

    const simulation_response = await fetch(this.prefix + "/simulation_state");
    const simulation_state = await simulation_response.json();

    const chamber_state = loadChamber(this.chamber, simulation_state);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);

    const arr = getChamberPixels(
      this.chamber,
      this.chamber_pixel_data,
      this.chamber_pixel_len,
    );
    arr.fill(0xff);

    this.chamber.instance.exports.render(
      chamber_state,
      this.chamber_pixel_data,
      this.canvas.width,
      this.canvas.height,
    );

    this.chamber.instance.exports.deinit(chamber_state);

    const img_data = new ImageData(arr, this.canvas.width, this.canvas.height);
    ctx.putImageData(img_data, 0, 0);

    ctx.beginPath();
    ctx.strokeStyle = "black";
    ctx.lineWidth = 0.01 * this.canvas.width;
    ctx.rect(0, 0, this.canvas.width, this.canvas.height);
    ctx.stroke();

    for (var i = 0; i < simulation_state.balls.length; ++i) {
      const ball = simulation_state.balls[i];
      // Everything is scaled relative to width
      const ball_x_px = ball.pos.x * this.canvas.width;
      // Y relative to bottom
      const ball_y_px = this.canvas.height - ball.pos.y * this.canvas.width;
      const ball_r_px = ball.r * this.canvas.width;

      ctx.beginPath();
      if (i % 2 == 0) {
        ctx.fillStyle = "red";
      } else {
        ctx.fillStyle = "blue";
      }

      ctx.arc(ball_x_px, ball_y_px, ball_r_px, 0, 2 * Math.PI);
      ctx.closePath();
      ctx.fill();
    }

    window.setTimeout(() => this.render(), 16);
  }
}

async function init() {
  const num_sims_response = await fetch("/num_simulations");
  num_simulations = await num_sims_response.json();

  const importObj = {
    env: { logWasm: wasmLog },
  };

  for (let i = 0; i < num_simulations; ++i) {
    const obj = await WebAssembly.instantiateStreaming(
      fetch("/" + i + "/chamber.wasm"),
      importObj,
    );
    new Chamber(i, obj);
  }
}

window.onload = init;
