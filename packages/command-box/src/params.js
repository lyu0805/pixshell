/**
 * Custom command parameter helpers
 * Template: "tail -n ${lines} -f ${file}"
 */
function parseParams(template) {
  const re = /\$\{([a-zA-Z0-9_]+)\}/g
  const names = []
  let m
  while ((m = re.exec(String(template || '')))) {
    if (!names.includes(m[1])) names.push(m[1])
  }
  return names
}

function renderTemplate(template, values = {}) {
  return String(template).replace(/\$\{([a-zA-Z0-9_]+)\}/g, (_, k) => {
    if (values[k] === undefined || values[k] === null) return `\${${k}}`
    return String(values[k])
  })
}

function hasUnresolved(template) {
  return parseParams(template).length > 0 && /\$\{[a-zA-Z0-9_]+\}/.test(template)
}

/** prompt missing params via callback ask(name) => string|Promise */
async function resolveInteractive(template, ask) {
  const names = parseParams(template)
  const values = {}
  for (const n of names) {
    values[n] = await ask(n)
  }
  return renderTemplate(template, values)
}

function applyDefaults(template, defaults = {}) {
  const names = parseParams(template)
  const values = {}
  for (const n of names) {
    if (defaults[n] !== undefined) values[n] = defaults[n]
  }
  return renderTemplate(template, values)
}

module.exports = { parseParams, renderTemplate, resolveInteractive, hasUnresolved, applyDefaults }
