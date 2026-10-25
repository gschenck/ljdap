// Minimaler DAP-Client für die Tests (TCP, Content-Length-Rahmen).
'use strict';
const net = require('net');

class Dap {
  constructor(port) {
    this.port = port;
    this.seq = 0;
    this.buf = Buffer.alloc(0);
    this.inbox = [];
    this.waiters = [];
  }
  connect() {
    return new Promise((resolve, reject) => {
      this.sock = net.connect(this.port, '127.0.0.1', resolve);
      this.sock.on('error', reject);
      this.sock.on('data', (d) => this.onData(d));
    });
  }
  onData(d) {
    this.buf = Buffer.concat([this.buf, d]);
    for (;;) {
      const h = this.buf.indexOf('\r\n\r\n');
      if (h < 0) return;
      const m = /Content-Length:\s*(\d+)/i.exec(this.buf.slice(0, h).toString());
      const len = Number(m[1]);
      if (this.buf.length < h + 4 + len) return;
      const msg = JSON.parse(this.buf.slice(h + 4, h + 4 + len).toString('utf8'));
      this.buf = this.buf.slice(h + 4 + len);
      this.inbox.push(msg);
      this.waiters = this.waiters.filter((w) => !w());
    }
  }
  waitFor(pred, ms = 10000, what = 'Nachricht') {
    return new Promise((resolve, reject) => {
      const check = () => {
        const i = this.inbox.findIndex(pred);
        if (i >= 0) { clearTimeout(t); resolve(this.inbox.splice(i, 1)[0]); return true; }
        return false;
      };
      const t = setTimeout(() => reject(new Error('Zeitüberschreitung: ' + what)), ms);
      if (!check()) this.waiters.push(check);
    });
  }
  async request(command, args = {}) {
    const seq = ++this.seq;
    const body = Buffer.from(JSON.stringify({ seq, type: 'request', command, arguments: args }));
    this.sock.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]));
    const r = await this.waitFor((m) => m.type === 'response' && m.request_seq === seq, 10000, command);
    if (!r.success) throw new Error(`${command}: ${r.message}`);
    return r;
  }
  event(name, ms) {
    return this.waitFor((m) => m.type === 'event' && m.event === name, ms, 'Event ' + name);
  }
  close() { if (this.sock) this.sock.destroy(); }
}
module.exports = { Dap };
