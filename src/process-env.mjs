export function childEnvironment(overrides = {}) {
  const inherited = {...process.env};
  for (const name of Object.keys(inherited)) {
    if (/^npm_config_(package|call)$/i.test(name)) delete inherited[name];
  }
  return {...inherited, ...overrides};
}
