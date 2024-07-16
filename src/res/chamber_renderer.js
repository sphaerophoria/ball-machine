export const canvas_width = 300;

function renderBorder(canvas, bounds) {
  const ctx = canvas.getContext("2d");
  for (const pos of getCanvasPositions(canvas, bounds)) {
    ctx.beginPath();
    ctx.strokeStyle = "black";
    ctx.lineWidth = 0.01 * bounds.width;
    ctx.rect(pos.x, pos.y, bounds.width, bounds.height);
    ctx.stroke();
  }
}

export function renderChamberIntoCanvas(chamber, canvas, bounds) {
  const ctx = canvas.getContext("2d");

  chamber.instance.exports.render(bounds.width, bounds.height);

  const canvas_data = new Uint8ClampedArray(
    chamber.instance.exports.memory.buffer,
    chamber.instance.exports.canvasMemory(),
    bounds.width * bounds.height * 4,
  );

  const img_data = new ImageData(canvas_data, bounds.width, bounds.height);

  for (const pos of getCanvasPositions(canvas, bounds)) {
    ctx.putImageData(img_data, pos.x, pos.y);
  }
  renderBorder(canvas, bounds);
}

export function clearBounds(canvas, bounds) {
  const ctx = canvas.getContext("2d");
  for (const pos of getCanvasPositions(canvas, bounds)) {
    ctx.fillStyle = "white";
    ctx.fillRect(pos.x, pos.y, bounds.width, bounds.height);
  }
  renderBorder(canvas, bounds);
}

function getCanvasPositions(canvas, bounds) {
  const wrapped_x = bounds.x % canvas.width;
  const wrapped_y = bounds.y % canvas.height;

  const x_positions = [wrapped_x];
  const y_positions = [wrapped_y];

  if (wrapped_x + bounds.width > canvas.width) {
    x_positions.push(wrapped_x - canvas.width);
  }

  if (wrapped_y + bounds.height > canvas.height) {
    y_positions.push(wrapped_y - canvas.height);
  }

  const ret = [];
  for (const x_pos of x_positions) {
    for (const y_pos of y_positions) {
      ret.push({
        x: x_pos,
        y: y_pos,
      });
    }
  }
  return ret;
}

export function renderBallsIntoCanvas(balls, canvas, bounds) {
  const ctx = canvas.getContext("2d");
  const canvas_positions = getCanvasPositions(canvas, bounds);
  for (var i = 0; i < balls.length; ++i) {
    const ball = balls[i];
    // Everything is scaled relative to width
    const ball_x_px = ball.pos.x * bounds.width;
    // Y relative to bottom
    const ball_y_px = bounds.height - ball.pos.y * bounds.width;
    const ball_r_px = ball.r * bounds.width;

    ctx.fillStyle = "red";
    ctx.lineWidth = 0.005 * bounds.width;

    for (const pos of canvas_positions) {
      ctx.beginPath();
      ctx.arc(ball_x_px + pos.x, ball_y_px + pos.y, ball_r_px, 0, 2 * Math.PI);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
    }
  }
}
