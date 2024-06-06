async function init() {
	/** @type HTMLCanvasElement */
	const canvas = document.getElementById("canvas");
	var ctx = canvas.getContext("2d");

	const simulation_response = await fetch("/simulation_state")
	const simulation_state = await simulation_response.json();

	const ball = simulation_state.ball;

	// Everything is scaled relative to width
	const ball_x_px = ball.pos.x * canvas.width;
	// Y relative to bottom
	const ball_y_px = canvas.height - ball.pos.y * canvas.width;
	const ball_r_px = ball.r * canvas.width;

	ctx.beginPath();
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	ctx.strokeStyle = "black";
	ctx.lineWidth = 5;
	ctx.rect(0, 0, canvas.width, canvas.height);
	ctx.stroke();

	ctx.beginPath();
	ctx.fillStyle = "red";
	ctx.arc(ball_x_px, ball_y_px, ball_r_px, 0, 2 * Math.PI)
	console.log("drawing ball");
	ctx.closePath();
	ctx.fill();

	for (obj of simulation_state.collision_objects) {
		ctx.beginPath();
		ctx.strokeStyle = "blue";
		ctx.moveTo(obj.a.x * canvas.width, canvas.height - obj.a.y * canvas.width);
		ctx.lineTo(obj.b.x * canvas.width, canvas.height - obj.b.y * canvas.width);
		ctx.lineWidth = 15;
		ctx.closePath();
		ctx.stroke();
	}

	window.setTimeout(init, 16);
}

window.onload = init;
