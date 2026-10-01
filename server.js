const http = require('http');
const os = require('os');

const PORT = process.env.PORT || 3000;
const VERSION = process.env.APP_VERSION || 'v1';
const COLOR = process.env.BG_COLOR || '#1d9e75';
const OWNER = process.env.OWNER_NAME || 'Maria Arpitha';
const LAB = process.env.LAB_NAME || 'ECS Fargate Lab';
const STARTED = new Date().toISOString();

function page() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${LAB} | ${OWNER}</title>
  <style>
    body { margin: 0; font-family: system-ui, -apple-system, sans-serif; background: ${COLOR};
           color: #fff; display: flex; min-height: 100vh; align-items: center; justify-content: center; }
    .card { background: rgba(0,0,0,0.25); padding: 2rem 2.5rem; border-radius: 14px;
            max-width: 520px; width: calc(100% - 3rem); }
    .lab { text-transform: uppercase; letter-spacing: 0.12em; font-size: 0.8rem; opacity: 0.85; margin: 0; }
    h1 { margin: 0.4rem 0 0.2rem; font-size: 2rem; }
    .sub { margin: 0 0 1.5rem; opacity: 0.9; }
    table { border-collapse: collapse; width: 100%; }
    td { padding: 6px 12px 6px 0; border-top: 1px solid rgba(255,255,255,0.15); }
    td:first-child { opacity: 0.8; width: 40%; }
    .badge { display: inline-block; background: rgba(255,255,255,0.2); padding: 2px 10px; border-radius: 999px; }
    footer { margin-top: 1.5rem; font-size: 0.85rem; opacity: 0.8; }
  </style>
</head>
<body>
  <div class="card">
    <p class="lab">${LAB}</p>
    <h1>Hello, I'm ${OWNER}</h1>
    <p class="sub">Node.js app in Docker, deployed on AWS ECS with images from ECR.</p>
    <table>
      <tr><td>Version</td><td><span class="badge">${VERSION}</span></td></tr>
      <tr><td>Task hostname</td><td>${os.hostname()}</td></tr>
      <tr><td>Started at</td><td>${STARTED}</td></tr>
      <tr><td>Secret loaded</td><td>${process.env.API_KEY ? 'yes' : 'no'}</td></tr>
    </table>
    <footer>Refresh the page: behind a load balancer, the hostname changes between tasks.</footer>
  </div>
</body>
</html>`;
}

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('ok');
  }
  console.log(`${new Date().toISOString()} ${req.method} ${req.url}`);
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(page());
});

server.listen(PORT, () => {
  console.log(`${LAB} ${VERSION} by ${OWNER} listening on port ${PORT}`);
});

process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully');
  server.close(() => process.exit(0));
});