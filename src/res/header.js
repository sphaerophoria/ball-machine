const header_html = `
<a href="/index.html">Simulation</a>
<a href="/upload.html">Upload</a>
<a href="/chamber_test.html">Chamber testing</a>
<a href="/user.html">User</a>
`;

var header = null;

async function appendAdmin() {
  const response = await fetch("/userinfo");
  const response_data = await response.json();
  if (response_data.is_admin === true) {
    const admin_link = document.createElement("a");
    admin_link.href = "/admin.html";
    admin_link.innerHTML = "Admin";
    header.appendChild(admin_link);
  }
}

function init() {
  header = document.createElement("div");
  header.innerHTML = header_html;
  document.body.insertBefore(header, document.body.firstChild);
  appendAdmin();
}

init();
