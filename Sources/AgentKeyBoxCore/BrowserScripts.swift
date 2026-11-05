import Foundation

/// App-owned scripts only, evaluated in an isolated WKContentWorld. No agent-supplied code,
/// selectors, markup, or values are evaluated. Website JavaScript is disabled in this MVP.
enum BrowserScripts {
  static let inspect = #"""
    const visible = e => !e.disabled && e.getClientRects().length > 0;
    const passwords = [...document.querySelectorAll('input[type="password"]')].filter(visible);
    if (passwords.length !== 1) return null;
    const password = passwords[0], form = password.form;
    if (!form || form.method.toLowerCase() !== 'post' ||
        (form.target && form.target !== '_self') ||
        form.enctype !== 'application/x-www-form-urlencoded') return null;
    const candidates = [...form.elements].filter(e => e instanceof HTMLInputElement &&
      ['text','email'].includes(e.type) && visible(e));
    if (candidates.length !== 1 || !password.name || !candidates[0].name ||
        password.name === candidates[0].name || form.elements.length > 100) return null;
    const username = candidates[0];
    if ([...form.elements].filter(e => e.name === username.name).length !== 1 ||
        [...form.elements].filter(e => e.name === password.name).length !== 1) return null;
    // Multi-step/OTP/challenge forms and submit-button overrides need a separate design.
    if ([...form.elements].some(e => e.hasAttribute('formaction') ||
        e.hasAttribute('formmethod') || e.hasAttribute('formtarget') ||
        e.autocomplete === 'one-time-code' || e.autocomplete === 'new-password')) return null;
    const target = new URL(form.action, document.baseURI);
    if (target.origin !== location.origin || target.username || target.password ||
        target.search || target.hash) return null;
    globalThis.__akbForm = {form, username, password, action: target.href,
      usernameName: username.name, passwordName: password.name};
    return target.href;
    """#

  static let submit = #"""
    const state = globalThis.__akbForm;
    delete globalThis.__akbForm;
    if (!state || !state.form.isConnected || !state.username.isConnected ||
        !state.password.isConnected || state.username.form !== state.form ||
        state.password.form !== state.form || state.form.action !== destination ||
        state.action !== destination || state.form.method.toLowerCase() !== 'post' ||
        (state.form.target && state.form.target !== '_self') ||
        state.username.name !== state.usernameName || state.password.name !== state.passwordName)
      return false;
    // No page event handlers: native form submission, not a click or page-supplied function.
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(state.username, username);
    setter.call(state.password, password);
    try {
      HTMLFormElement.prototype.submit.call(state.form);
      return true;
    } catch (_) {
      setter.call(state.username, ''); setter.call(state.password, '');
      return false;
    }
    """#

  static let inspectRecovery = #"""
    delete globalThis.__akbRecoveryForm;
    const names = ['recovery_code', 'recovery-code'];
    const fields = [...document.querySelectorAll('input')].filter(e => names.includes(e.name));
    if (fields.length !== 1 || document.querySelector('input[type="password"]')) return null;
    const code = fields[0], form = code.form;
    if (!form || code.type !== 'text' || code.disabled || code.readOnly ||
        !code.getClientRects().length || form.method.toLowerCase() !== 'post' ||
        form.enctype !== 'application/x-www-form-urlencoded' ||
        (form.target && form.target !== '_self') || form.elements.length > 100) return null;
    if ([...form.elements].some(e => e.hasAttribute('formaction') ||
        e.hasAttribute('formmethod') || e.hasAttribute('formtarget') ||
        (e !== code && e.name === code.name) ||
        (e !== code && !e.disabled && !['hidden','submit','button'].includes(e.type)))) return null;
    const target = new URL(form.action, document.baseURI);
    if (target.origin !== location.origin || target.username || target.password ||
        target.search || target.hash) return null;
    globalThis.__akbRecoveryForm = {form, code, action: target.href, name: code.name};
    return target.href;
    """#

  static let submitRecovery = #"""
    const state = globalThis.__akbRecoveryForm;
    delete globalThis.__akbRecoveryForm;
    if (!state || !state.form.isConnected || !state.code.isConnected ||
        state.code.form !== state.form || state.form.action !== destination ||
        state.action !== destination || state.form.method.toLowerCase() !== 'post' ||
        state.form.enctype !== 'application/x-www-form-urlencoded' ||
        (state.form.target && state.form.target !== '_self') || state.code.name !== state.name ||
        state.code.disabled || state.code.readOnly) return false;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(state.code, code);
    try { HTMLFormElement.prototype.submit.call(state.form); return true; }
    catch (_) { setter.call(state.code, ''); return false; }
    """#

  static let page = #"""
    // Never serialize HTML, attributes, form values, cookies, storage, frames, or scripts.
    if (document.querySelector('input[type="password"],input[autocomplete="one-time-code"],input[name="recovery_code"],input[name="recovery-code"]'))
      return null;
    const root = document.body;
    if (!root) return null;
    const blocked = 'script,style,noscript,template,input,textarea,select,option,iframe,object,embed,[hidden]';
    const visible = e => e && !e.closest(blocked) && e.getClientRects().length &&
      !['hidden', 'collapse'].includes(getComputedStyle(e).visibility);
    const visibleText = (element, limit, separator) => {
      const walk = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
      let text = '', node, count = 0;
      while ((node = walk.nextNode()) && count++ < 20000 && text.length <= limit) {
        if (!visible(node.parentElement)) continue;
        text += (node.textContent + separator).slice(0, limit + 1 - text.length);
      }
      return {text: text.slice(0, limit), truncated: count >= 20000 || text.length > limit};
    };
    const body = visibleText(root, 100000, '\n');
    const links = [...root.querySelectorAll('a[href]')].slice(0, 100).filter(visible).map(e => {
      const label = visibleText(e, 500, '');
      return {text: label.text, href: e.href, truncated: label.truncated};
    });
    return {title: document.title.slice(0, 2000), titleTruncated: document.title.length > 2000,
      text: body.text, textTruncated: body.truncated || body.text.length >= 100000, links};
    """#
}
