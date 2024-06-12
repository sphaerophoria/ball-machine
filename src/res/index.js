var chambers = [];
var chambers_pixel_data = [];

function wasmLog(chamber, s, len) {
  var uint_arr = new Uint8Array(chamber.instance.exports.memory.buffer, s, len);
  var dec = new TextDecoder();
  const str = dec.decode(uint_arr);
  console.log(str);
}

function getChamberPixels(chamber, chamber_pixel_data) {
  const offs = chamber.instance.exports.slicePtr(chamber_pixel_data);
  const len = chamber.instance.exports.sliceLen(chamber_pixel_data);

  return new Uint8ClampedArray(
    chamber.instance.exports.memory.buffer,
    offs,
    len,
  );
}

function loadChamber(chamber, simulation_state) {
  const chamber_save = chamber.instance.exports.alloc(
    simulation_state.chamber_state.length,
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
  const simulation_response = await fetch("/simulation_state");
  const simulation_state = await simulation_response.json();

  for (let i = 0; i < simulation_state.length; ++i) {
    /** @type HTMLCanvasElement */
    const canvas = document.getElementById("canvas" + (i + 1));
    var ctx = canvas.getContext("2d");

    const chamber_state = loadChamber(chambers[i], simulation_state[i]);
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const arr = getChamberPixels(chambers[i], chambers_pixel_data[i]);
    arr.fill(0xff);

    chambers[i].instance.exports.render(
      chamber_state,
      chambers_pixel_data[i],
      canvas.width,
      canvas.height,
    );

    chambers[i].instance.exports.deinit(chamber_state);

    const img_data = new ImageData(arr, canvas.width, canvas.height);
    ctx.putImageData(img_data, 0, 0);

    ctx.beginPath();
    ctx.strokeStyle = "black";
    ctx.lineWidth = 0.01 * canvas.width;
    ctx.rect(0, 0, canvas.width, canvas.height);
    ctx.stroke();

    for (let j = 0; j < simulation_state[i].balls.length; ++j) {
      const ball = simulation_state[i].balls[j];
      // Everything is scaled relative to width
      const ball_x_px = ball.pos.x * canvas.width;
      // Y relative to bottom
      const ball_y_px = canvas.height - ball.pos.y * canvas.width;
      const ball_r_px = ball.r * canvas.width;

      ctx.beginPath();
      if (j % 2 == 0) {
        ctx.fillStyle = "red";
      } else {
        ctx.fillStyle = "blue";
      }

      ctx.arc(ball_x_px, ball_y_px, ball_r_px, 0, 2 * Math.PI);
      ctx.closePath();
      ctx.fill();
    }
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
      const chamber = obj;
      chambers.push(obj);

      const canvas = document.getElementById("canvas1");
      const chamber_pixel_data = chamber.instance.exports.alloc(
        canvas.width * canvas.height * 4,
      );
      chambers_pixel_data.push(chamber_pixel_data);

      WebAssembly.instantiateStreaming(fetch("/chamber.wasm"), importObj).then(
        (obj) => {
          const chamber = obj;
          chambers.push(obj);

          const canvas = document.getElementById("canvas2");
          const chamber_pixel_data = chamber.instance.exports.alloc(
            canvas.width * canvas.height * 4,
          );
          chambers_pixel_data.push(chamber_pixel_data);
          render();
        },
      );
    },
  );
}

window.onload = init;
