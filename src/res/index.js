var chamber = null;
var chamber_pixel_data = null;

function wasmLog(s, len) {
  var uint_arr = new Uint8Array(chamber.instance.exports.memory.buffer, s, len);
  var dec = new TextDecoder();
  const str = dec.decode(uint_arr);
  console.log(str);
}

function getChamberPixels() {
  const offs = chamber.instance.exports.slicePtr(chamber_pixel_data);
  const len = chamber.instance.exports.sliceLen(chamber_pixel_data);

  return new Uint8ClampedArray(
    chamber.instance.exports.memory.buffer,
    offs,
    len,
  );
}

function loadChamber(simulation_state) {
  const chamber_save = chamber.instance.exports.alloc(
    simulation_state.chamber_state.length,
    1,
  );
  const offset = chamber.instance.exports.slicePtr(chamber_save);
  const len = chamber.instance.exports.sliceLen(chamber_save);
  const arr = new Uint8Array(
    chamber.instance.exports.memory.buffer,
    offset,
    len,
  );
  arr.set(simulation_state.chamber_state);

  const chamber_state = chamber.instance.exports.load(chamber_save);
  chamber.instance.exports.free(chamber_save);
  return chamber_state;
}

async function render() {
  /** @type HTMLCanvasElement */
  const canvas = document.getElementById("canvas");
  var ctx = canvas.getContext("2d");

  const simulation_response = await fetch("/simulation_state");
  const simulation_state = await simulation_response.json();

  const chamber_state = loadChamber(simulation_state);
  ctx.clearRect(0, 0, canvas.width, canvas.height);

  const arr = getChamberPixels();
  arr.fill(0xff);

  chamber.instance.exports.render(
    chamber_state,
    chamber_pixel_data,
    canvas.width,
    canvas.height,
  );

  chamber.instance.exports.deinit(chamber_state);

  const img_data = new ImageData(arr, canvas.width, canvas.height);
  ctx.putImageData(img_data, 0, 0);

  ctx.beginPath();
  ctx.strokeStyle = "black";
  ctx.lineWidth = 0.01 * canvas.width;
  ctx.rect(0, 0, canvas.width, canvas.height);
  ctx.stroke();

  for (var i = 0; i < simulation_state.balls.length; ++i) {
    const ball = simulation_state.balls[i];
    // Everything is scaled relative to width
    const ball_x_px = ball.pos.x * canvas.width;
    // Y relative to bottom
    const ball_y_px = canvas.height - ball.pos.y * canvas.width;
    const ball_r_px = ball.r * canvas.width;

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

  window.setTimeout(render, 16);
}

async function init() {
  const save_button = document.getElementById("save");
  save_button.onclick = () => fetch("/save");
  const importObj = {
    env: { logWasm: wasmLog },
  };

  WebAssembly.instantiateStreaming(fetch("/chamber.wasm"), importObj).then(
    (obj) => {
      chamber = obj;

      const canvas = document.getElementById("canvas");
      chamber_pixel_data = chamber.instance.exports.alloc(
        canvas.width * canvas.height * 4,
        4,
      );

      render();
    },
  );
}

window.onload = init;
