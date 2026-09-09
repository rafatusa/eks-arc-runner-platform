import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Failure rate and latency are tracked separately from k6's built-in metrics so
// the thresholds below describe the SERVICE, not the test harness.
const errorRate = new Rate('application_errors');
const healthLatency = new Trend('health_latency');

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  scenarios: {
    ramping_load: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 10 },
        { duration: '60s', target: 25 },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '15s',
    },
  },
  thresholds: {
    // A failed threshold fails the stage — this is the pass/fail gate.
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<800', 'p(99)<1500'],
    application_errors: ['rate<0.01'],
  },
};

export default function () {
  const landing = http.get(`${BASE_URL}/`);
  check(landing, {
    'landing page returns 200': (r) => r.status === 200,
    'landing page is HTML': (r) => String(r.headers['Content-Type'] || '').includes('text/html'),
  }) || errorRate.add(1);

  const health = http.get(`${BASE_URL}/health`);
  healthLatency.add(health.timings.duration);
  check(health, {
    'health returns 200': (r) => r.status === 200,
    'health reports UP': (r) => {
      try {
        return r.json('status') === 'UP';
      } catch (e) {
        return false;
      }
    },
  }) || errorRate.add(1);

  const hello = http.get(`${BASE_URL}/hello?name=k6`);
  check(hello, {
    'hello returns 200': (r) => r.status === 200,
    'hello greets the caller': (r) => {
      try {
        return r.json('message') === 'Hello, k6!';
      } catch (e) {
        return false;
      }
    },
  }) || errorRate.add(1);

  errorRate.add(0);
  sleep(1);
}

export function handleSummary(data) {
  return {
    'reports/k6-summary.json': JSON.stringify(data, null, 2),
    stdout: textSummary(data),
  };
}

// Minimal textual summary — avoids depending on a remote jslib module, which
// would make the load stage fail whenever that CDN is unreachable.
function textSummary(data) {
  const m = data.metrics;
  const line = (label, value) => `  ${label.padEnd(28)} ${value}\n`;
  const get = (name, field, digits = 2) => {
    const metric = m[name];
    if (!metric || metric.values[field] === undefined) return 'n/a';
    return Number(metric.values[field]).toFixed(digits);
  };

  let out = '\nk6 load test summary\n====================\n';
  out += line('requests', get('http_reqs', 'count', 0));
  out += line('request failure rate', get('http_req_failed', 'rate', 4));
  out += line('avg duration (ms)', get('http_req_duration', 'avg'));
  out += line('p95 duration (ms)', get('http_req_duration', 'p(95)'));
  out += line('p99 duration (ms)', get('http_req_duration', 'p(99)'));
  out += line('max duration (ms)', get('http_req_duration', 'max'));
  out += line('application error rate', get('application_errors', 'rate', 4));
  out += '\n';
  return out;
}
