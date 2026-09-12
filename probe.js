const kPipelineCount = 100;
const kRounds = 64;
const kVertex = `@vertex fn main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  let p = array(vec2f(-1., -1.), vec2f(3., -1.), vec2f(-1., 3.));
  return vec4f(p[i], 0., 1.);
}`;

function Shader(constants) {
  const declarations = constants.map((value, index) => `const s${index}: u32 = ${value}u;`).join('\n');
  const body = Array.from({length: kRounds}, (_, index) => `
    x = (x ^ (y >> 7u)) * 1664525u + s${index % 4};
    y = (y ^ (z >> 9u)) * 22695477u + s${(index + 1) % 4};
    z = (z ^ (w >> 13u)) * 1103515245u + s${(index + 2) % 4};
    w = (w ^ (x >> 11u)) * 214013u + s${(index + 3) % 4};`).join('\n');
  return `${declarations}
@fragment fn main(@builtin(position) p: vec4f) -> @location(0) vec4u {
  var x = u32(p.x) + s0; var y = s1; var z = s2; var w = s3;
  ${body}
  return vec4u(x, y, z, w);
}`;
}

function Expected(constants, index) {
  let [x, y, z, w] = constants;
  x = (x + index) >>> 0;
  for(let round = 0; round < kRounds; ++round) {
    x = (Math.imul(x ^ (y >>> 7), 1664525) + constants[round % 4]) >>> 0;
    y = (Math.imul(y ^ (z >>> 9), 22695477) + constants[(round + 1) % 4]) >>> 0;
    z = (Math.imul(z ^ (w >>> 13), 1103515245) + constants[(round + 2) % 4]) >>> 0;
    w = (Math.imul(w ^ (x >>> 11), 214013) + constants[(round + 3) % 4]) >>> 0;
  }
  return [x, y, z, w];
}

async function DrawAndValidate(device, pipelines, texture, output, constants) {
  const start = performance.now();
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginRenderPass({colorAttachments: [{view: texture.createView(),
    loadOp: 'clear', storeOp: 'store', clearValue: {r: 0, g: 0, b: 0, a: 0}}]});
  pipelines.forEach((pipeline, index) => {
    pass.setPipeline(pipeline);
    pass.setScissorRect(index, 0, 1, 1);
    pass.draw(3);
  });
  pass.end();
  encoder.copyTextureToBuffer({texture}, {buffer: output, bytesPerRow: output.size}, [kPipelineCount, 1]);
  device.queue.submit([encoder.finish()]);
  await output.mapAsync(GPUMapMode.READ);
  const elapsed = performance.now() - start;
  const actual = new Uint32Array(output.getMappedRange());
  const mismatches = [];
  constants.forEach((values, index) => {
    Expected(values, index).forEach((expected, channel) => {
      if(actual[index * 4 + channel] !== expected) {
        mismatches.push({index, channel, expected, actual: actual[index * 4 + channel]});
      }
    });
  });
  output.unmap();
  if(mismatches.length) {
    throw new Error(`Output validation failed: ${JSON.stringify(mismatches)}`);
  }
  return elapsed;
}

async function RunProbe() {
  let device;
  let renderTimer;
  let heartbeatTimer;
  const visibility = [document.visibilityState];
  const onVisibility = () => visibility.push(document.visibilityState);
  document.addEventListener('visibilitychange', onVisibility);
  try {
    if(!navigator.gpu) {
      throw new Error('WebGPU is unavailable. Serve this page on localhost or HTTPS.');
    }
    const adapter = await navigator.gpu.requestAdapter();
    if(!adapter) {
      throw new Error('No WebGPU adapter.');
    }
    device = await adapter.requestDevice();
    const errors = [];
    device.addEventListener('uncapturederror', event => errors.push(event.error.message));
    device.pushErrorScope('validation');
    const vertex = device.createShaderModule({code: kVertex});
    const layout = device.createPipelineLayout({bindGroupLayouts: []});
    const canvas = document.getElementById('surface');
    const context = canvas.getContext('webgpu');
    const format = navigator.gpu.getPreferredCanvasFormat();
    context.configure({device, format, alphaMode: 'opaque'});
    const fragment = device.createShaderModule({code:
      '@fragment fn main() -> @location(0) vec4f { return vec4f(0.2, 0.8, 0.5, 1.); }'});
    const animationPipeline = await device.createRenderPipelineAsync({layout,
      vertex: {module: vertex, entryPoint: 'main'},
      fragment: {module: fragment, entryPoint: 'main', targets: [{format}]}});

    // Compile-independent animation on the SAME device, to exercise presentation.
    let frame = 0;
    renderTimer = setInterval(() => {
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({colorAttachments: [{
        view: context.getCurrentTexture().createView(), loadOp: 'clear', storeOp: 'store',
        clearValue: {r: 0.04, g: 0.07, b: 0.1, a: 1}}]});
      pass.setPipeline(animationPipeline);
      const travel = canvas.width - 32;
      const offset = (frame++ * 4) % (travel * 2);
      pass.setScissorRect(travel - Math.abs(travel - offset), 32, 32, 32);
      pass.draw(3);
      pass.end();
      device.queue.submit([encoder.finish()]);
    }, 16);
    await new Promise(resolve => setTimeout(resolve, 250));

    // Every reload changes executable constants, not comments or unused code.
    const constants = Array.from({length: kPipelineCount}, () =>
      Array.from(crypto.getRandomValues(new Uint32Array(4))));
    const sources = constants.map(Shader);
    ShowStatus('Compiling 100 fresh pipelines. Watch the moving square.');
    const start = performance.now();
    let previous = start;
    let maxTimerGapMs = 0;
    heartbeatTimer = setInterval(() => {
      const now = performance.now();
      maxTimerGapMs = Math.max(maxTimerGapMs, now - previous);
      previous = now;
    }, 4);
    const modules = sources.map(code => device.createShaderModule({code}));
    const modulesSubmittedMs = performance.now() - start;
    const requests = modules.map(module => device.createRenderPipelineAsync({layout,
      vertex: {module: vertex, entryPoint: 'main'},
      fragment: {module, entryPoint: 'main', targets: [{format: 'rgba32uint'}]}}));
    const submittedMs = performance.now() - start;
    const pipelines = await Promise.all(requests);
    const readyMs = performance.now() - start;
    // Observe timer delivery after compilation; this does not pace submissions.
    await new Promise(resolve => setTimeout(resolve, 32));
    clearInterval(heartbeatTimer);
    ShowStatus('Promises resolved. Measuring and validating first and repeat draws.');

    const texture = device.createTexture({size: [kPipelineCount, 1], format: 'rgba32uint',
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC});
    const output = device.createBuffer({size: Math.ceil(kPipelineCount * 16 / 256) * 256,
      usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ});
    const firstUseMs = await DrawAndValidate(device, pipelines, texture, output, constants);
    const secondUseMs = await DrawAndValidate(device, pipelines, texture, output, constants);
    output.destroy();
    texture.destroy();
    const validation = await device.popErrorScope();
    if(validation) {
      errors.push(validation.message);
    }
    if(errors.length) {
      throw new Error(errors.join('\n'));
    }
    return {userAgent: navigator.userAgent, date: new Date().toISOString(), visibility,
      adapter: {vendor: adapter.info.vendor, architecture: adapter.info.architecture,
        device: adapter.info.device, description: adapter.info.description},
      pipelineCount: kPipelineCount, rounds: kRounds, constants,
      modulesSubmittedMs, submittedMs, readyMs, firstUseMs, secondUseMs, maxTimerGapMs,
      validatedValues: kPipelineCount * 4 * 2, errors};
  } catch(error) {
    clearInterval(renderTimer);
    device?.destroy();
    throw error;
  } finally {
    clearInterval(heartbeatTimer);
    document.removeEventListener('visibilitychange', onVisibility);
  }
}

window.probeResult = null;
window.probeError = null;
RunProbe().then(result => {
  window.probeResult = result;
  ShowResults(result);
}).catch(error => {
  window.probeError = String(error.stack || error);
  ShowStatus(`Test failed: ${window.probeError}`);
});
