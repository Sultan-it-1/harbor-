async function test() {
  try {
    const res = await fetch('https://api.strem.io/api/login', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        email: 'test@example.com',
        password: 'password',
        facebook: false
      })
    });
    console.log('Status:', res.status);
    console.log('Headers:', Object.fromEntries(res.headers.entries()));
    const text = await res.text();
    console.log('Body:', text.substring(0, 1000));
  } catch (e) {
    console.error('Error:', e);
  }
}

test();
