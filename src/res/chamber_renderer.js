export const canvas_width = 600;

export class ChamberRenderer {
  constructor(parent, chamber_height) {
    this.canvas = document.createElement("canvas");
    parent.appendChild(this.canvas);

    this.canvas.width = canvas_width;
    this.canvas.height = this.canvas.width * chamber_height;
  }

  getCtx() {
    return this.canvas.getContext("2d");
  }

  renderBorder() {
    const ctx = this.getCtx();
    ctx.beginPath();
    ctx.strokeStyle = "black";
    ctx.lineWidth = 0.01 * this.canvas.width;
    ctx.rect(0, 0, this.canvas.width, this.canvas.height);
    ctx.stroke();
  }

  renderBalls(balls) {
    const ctx = this.getCtx();

    for (var i = 0; i < balls.length; ++i) {
      const ball = balls[i];
      // Everything is scaled relative to width
      const ball_x_px = ball.pos.x * this.canvas.width;
      // Y relative to bottom
      const ball_y_px = this.canvas.height - ball.pos.y * this.canvas.width;
      const ball_r_px = ball.r * this.canvas.width;

      ctx.beginPath();
      ctx.fillStyle = "red";
      ctx.lineWidth = 0.005 * this.canvas.width;

      ctx.arc(ball_x_px, ball_y_px, ball_r_px, 0, 2 * Math.PI);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
    }
  }

  renderChamber(chamber) {
    const ctx = this.getCtx();

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
  }

  renderPopulatedChamber(balls, chamber) {
    this.renderChamber(chamber);
    this.renderBorder();
    this.renderBalls(balls);
  }

  renderEmptyChamber(balls) {
    const ctx = this.getCtx();

    ctx.fillStyle = "white";
    ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

    this.renderBorder();
    this.renderBalls(balls);
  }
}
