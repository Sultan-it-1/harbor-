import http from 'http';
import express from 'express';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 1421;

// Proxy Middleware for /api-proxy/
app.use('/api-proxy/', async (req, res) => {
  const url = req.url; // Express strips the mount path, so req.url is the path AFTER /api-proxy/
  // But wait, actually express req.originalUrl contains the full thing.
  // It's safer to reconstruct the target URL:
  const match = req.originalUrl.match(/^\/api-proxy\/([^/]+)(.*)$/);
  if (!match) {
    res.status(404).send('Not Found');
    return;
  }

  const targetHost = match[1];
  const targetPath = match[2];
  const targetUrl = `https://${targetHost}${targetPath}`;

  const bodyChunks = [];
  req.on('data', (chunk) => bodyChunks.push(chunk));
  req.on('end', async () => {
    const body = Buffer.concat(bodyChunks);

    const headers = { ...req.headers };
    delete headers.host;
    delete headers.connection;
    if (headers['x-harbor-auth']) {
      headers['authorization'] = headers['x-harbor-auth'];
      delete headers['x-harbor-auth'];
    }

    headers['user-agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

    try {
      const response = await fetch(targetUrl, {
        method: req.method,
        headers: headers,
        body: req.method !== 'GET' && req.method !== 'HEAD' && body.length > 0 ? body : undefined
      });

      res.status(response.status);
      response.headers.forEach((value, key) => {
        if (key !== 'content-encoding' && key !== 'transfer-encoding') {
          res.setHeader(key, value);
        }
      });

      const responseBody = await response.arrayBuffer();
      res.end(Buffer.from(responseBody));
    } catch (err) {
      console.error('Proxy Fetch Error:', err.message, 'for target:', targetUrl);
      res.status(502).json({ error: err.message });
    }
  });
});

// Serve static frontend files from 'dist'
app.use(express.static(path.join(__dirname, 'dist')));

// Fallback to index.html for client-side routing
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'dist', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`Cloud Server listening on port ${PORT}`);
});
