#!/usr/bin/env node
// Exercise the real illustration script without a browser or third-party DOM library.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const script = await readFile(new URL('../website/assets/demo.js', import.meta.url), 'utf8');
function fixture(reduce = false) {
    class Element {
        dataset = {};
        attributes = {};
        listeners = {};
        textContent = '';
        hidden = false;
        disabled = true;
        style = { setProperty() {} };
        classList = { toggle() {}, add() {} };
        setAttribute(key, value) { this.attributes[key] = value; }
        addEventListener(event, handler) { this.listeners[event] = handler; }
        replaceChildren(child) { this.child = child; }
        querySelector(selector) { return this.elements[selector]; }
        querySelectorAll(selector) { return this.elements[selector]; }
        click() { this.listeners.click(); }
    }
    const demo = new Element();
    const elements = Object.fromEntries(['[data-composition]', '[data-committed]', '[data-candidates]', '[data-toggle]', '[data-scene-status]', '[data-key-hint]', '[data-space-key]', '[data-replay]', '[data-playback]', '[data-toggle-label]', '[data-toggle-icon]'].map(key => [key, new Element()]));
    const buttons = Array.from({ length: 3 }, (_, index) => {
        const button = new Element();
        button.elements = { '[data-scene-title]': { textContent: `Scene ${index}` }, '[data-scene-description]': { textContent: 'Description' } };
        return button;
    });
    elements['[data-scene]'] = buttons;
    elements['[data-scene-candidates]'] = buttons.map((_, scene) => ({ content: { cloneNode: () => ({ scene }) } }));
    demo.elements = elements;
    demo.dataset = { pauseLabel: 'Pause', playLabel: 'Play', keyHint: 'Space', literalHint: 'Return', resultHint: 'Committed' };
    const documentListeners = {};
    const document = { hidden: false, querySelector: () => demo, querySelectorAll: () => [], addEventListener: (event, handler) => { documentListeners[event] = handler; } };
    let motionListener;
    const motion = { matches: reduce, addEventListener: (_, handler) => { motionListener = handler; } };
    let frame;
    let clock = 0;
    const observers = [];
    class IntersectionObserver {
        constructor(callback) { this.callback = callback; observers.push(this); }
        observe(target) { this.target = target; }
        unobserve() {}
    }
    vm.runInNewContext(script, {
        window: { matchMedia: () => motion, IntersectionObserver }, document, IntersectionObserver,
        requestAnimationFrame: handler => { frame = handler; return 1; }, cancelAnimationFrame: () => { frame = undefined; },
    });
    return {
        demo, elements, buttons, document,
        advance(milliseconds) { clock += milliseconds; const handler = frame; frame = undefined; handler?.(clock); },
        hasFrame: () => !!frame,
        setMotion(value) { motion.matches = value; motionListener(); },
        setHidden(value) { document.hidden = value; documentListeners.visibilitychange(); },
        setVisible(value) { observers.find(observer => observer.target === demo).callback([{ isIntersecting: value }]); },
    };
}
const state = fixture();
assert.equal(state.hasFrame(), true);
for (const [index, input, result, key] of [[0, 'shi', '', 'space'], [1, 'woxiangyaodeploy', '我想要deploy', 'space'], [2, 'SI_build42', 'SI_build42', 'return']]) {
    state.buttons[index].click();
    assert.equal(state.elements['[data-composition]'].textContent, input);
    assert.equal(state.elements['[data-candidates]'].hidden, false, 'Manual steps must show complete candidates');
    assert.equal(state.elements['[data-candidates]'].child.scene, index);
    assert.equal(state.elements['[data-space-key]'].textContent, key);
    assert.equal(state.hasFrame(), false, 'Manual steps stay still');
    assert.equal(state.buttons[index].attributes['aria-pressed'], 'true');
    state.elements['[data-toggle]'].click();
    state.advance(0);
    state.advance(1500);
    assert.equal(state.elements['[data-committed]'].textContent, result);
    if (result) assert.equal(state.elements['[data-candidates]'].hidden, true);
}
state.setHidden(true);
assert.equal(state.hasFrame(), false);
state.setHidden(false);
assert.equal(state.hasFrame(), true);
state.setVisible(false);
assert.equal(state.hasFrame(), false);
state.setVisible(true);
state.elements['[data-replay]'].click();
assert.equal(state.demo.dataset.scene, '0');
assert.equal(state.elements['[data-committed]'].textContent, '');
state.setMotion(true);
assert.equal(state.hasFrame(), false);
assert.equal(state.elements['[data-composition]'].textContent, 'shi');
const reduced = fixture(true);
assert.equal(reduced.hasFrame(), false);
assert.equal(reduced.elements['[data-composition]'].textContent, 'shi');
assert.equal(reduced.elements['[data-candidates]'].hidden, false);
reduced.buttons[1].click();
assert.equal(reduced.elements['[data-composition]'].textContent, 'woxiangyaodeploy');
reduced.elements['[data-toggle]'].click();
assert.equal(reduced.hasFrame(), true, 'Explicit playback remains available with reduced motion');
console.log('Verified three manual scenes, exact commits, pause/replay, reduced motion, and hidden/offscreen suspension.');
