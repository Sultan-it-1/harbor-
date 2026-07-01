import http from 'http';

const PORT = 1421;

const server = http.createServer((req, res) => {
  // Enable CORS for localhost
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');

  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    res.end();
    return;
  }

  const url = req.url || '';
  if (url.startsWith('/api-proxy/')) {
    const match = url.match(/^\/api-proxy\/([^/]+)(.*)$/);
    if (match) {
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

        // Set User-Agent to mimic browser request to avoid blocks
        headers['user-agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

        try {
          const response = await fetch(targetUrl, {
            method: req.method,
            headers: headers,
            body: req.method !== 'GET' && req.method !== 'HEAD' && body.length > 0 ? body : undefined
          });

          res.statusCode = response.status;
          response.headers.forEach((value, key) => {
            if (key !== 'content-encoding' && key !== 'transfer-encoding') {
              res.setHeader(key, value);
            }
          });

          const responseBody = await response.arrayBuffer();
          res.end(Buffer.from(responseBody));
        } catch (err) {
          console.error('Proxy Fetch Error:', err.message, 'for target:', targetUrl);
          res.statusCode = 502;
          res.end(JSON.stringify({ error: err.message }));
        }
      });
      return;
    }
  }

  res.statusCode = 404;
  res.end('Not Found');
});

server.listen(PORT, () => {
  console.log(`Proxy server listening on port ${PORT}`);
});
