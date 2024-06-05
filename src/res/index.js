async function init() {
	/** @type HTMLCanvasElement */
	const canvas = document.getElementById("canvas");
	var ctx = canvas.getContext("2d");

	const ball_response = await fetch("/ball")
	const ball = await ball_response.json();
	// Everything is scaled relative to width
	const ball_x_px = ball.pos.x * canvas.width;
	// Y relative to bottom
	const ball_y_px = canvas.height - ball.pos.y * canvas.width;
	const ball_r_px = ball.r * canvas.width;

	ctx.beginPath();
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	ctx.fillStyle = "black";
	ctx.lineWidth = 5;
	ctx.rect(0, 0, canvas.width, canvas.height);
	ctx.stroke();

	ctx.beginPath();
	ctx.fillStyle = "red";
	ctx.arc(ball_x_px, ball_y_px, ball_r_px, 0, 2 * Math.PI)
	console.log("drawing ball");
	ctx.closePath();
	ctx.fill();

	window.setTimeout(init, 33);
}

window.onload = init;
