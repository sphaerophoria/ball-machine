const header_html = `
<a href="/index.html">Simulation</a>
<a href="/upload.html">Upload</a>
`;

function init() {
  const header = document.createElement("div");
  header.innerHTML = header_html;
  document.body.insertBefore(header, document.body.firstChild);
}

init();
