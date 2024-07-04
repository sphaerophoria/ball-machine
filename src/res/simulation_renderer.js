export class SimulationRenderer {
  constructor(parent, chamber_height) {
    const top_div = document.createElement("div");
    const canvas_div = document.createElement("div");
    top_div.append(canvas_div);

    this.canvas = document.createElement("canvas");
    canvas_div.appendChild(this.canvas);

    this.canvas.width = 600;
    this.canvas.height = this.canvas.width * chamber_height;

    this.reset_button = document.createElement("button");
    top_div.append(this.reset_button);

    this.reset_button.innerHTML = "Reset";
    parent.appendChild(top_div);
  }

  render(balls, chamber) {
    var ctx = this.canvas.getContext("2d");

    chamber.instance.exports.render(this.canvas.width, this.canvas.height);

    const canvas_data = new Uint8ClampedArray(
      chamber.instance.exports.memory.buffer,
      chamber.instance.exports.canvasMemory(),
      this.canvas.width * this.canvas.height * 4,
    );

    const img_data = new ImageData(
      canvas_data,
      this.canvas.width,
      this.canvas.height,
    );
    ctx.putImageData(img_data, 0, 0);

    ctx.beginPath();
    ctx.strokeStyle = "black";
    ctx.lineWidth = 0.01 * this.canvas.width;
    ctx.rect(0, 0, this.canvas.width, this.canvas.height);
    ctx.stroke();

    for (var i = 0; i < balls.length; ++i) {
      const ball = balls[i];
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
  }
}
