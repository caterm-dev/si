// Scripted illustrations only: this is not a second implementation of SI's engine.
(() => {
    const demo = document.querySelector('[data-demo]');
    if (!demo) return;
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
    const buttons = [...demo.querySelectorAll('[data-scene]')];
    const composition = demo.querySelector('[data-composition]');
    const committed = demo.querySelector('[data-committed]');
    const candidates = demo.querySelector('[data-candidates]');
    const templates = [...demo.querySelectorAll('[data-scene-candidates]')];
    const toggle = demo.querySelector('[data-toggle]');
    const status = demo.querySelector('[data-scene-status]');
    const keyHint = demo.querySelector('[data-key-hint]');
    const space = demo.querySelector('[data-space-key]');
    const scenes = [
        { input: 'shi', prefix: '', result: null, duration: 5100 },
        { input: 'nihao', prefix: '', result: '你好', duration: 5700 },
        { input: 'world', prefix: '你好', result: '你好world ', duration: 6300 },
    ];
    let scene = 0;
    let elapsed = 0;
    let playing = !reducedMotion.matches;
    let lastTime = null;
    let frame = null;
    let onScreen = true;

    function updateControl() {
        const label = playing ? demo.dataset.pauseLabel : demo.dataset.playLabel;
        toggle.setAttribute('aria-label', label);
        demo.querySelector('[data-toggle-label]').textContent = label;
        demo.querySelector('[data-toggle-icon]').textContent = playing ? 'Ⅱ' : '▷';
        demo.dataset.paused = String(!playing || !onScreen || document.hidden);
    }

    function render() {
        const current = scenes[scene];
        const typedAt = 400;
        const commitAt = 3500;
        const isCommitted = current.result !== null && elapsed >= commitAt;
        const length = Math.max(0, Math.min(current.input.length, Math.floor((elapsed - typedAt) / 170) + 1));
        composition.textContent = isCommitted ? '' : current.input.slice(0, length);
        committed.textContent = isCommitted ? current.result : current.prefix;
        candidates.hidden = length < current.input.length || isCommitted;
        space.classList.toggle('is-pressed', isCommitted && elapsed < commitAt + 350);
        space.hidden = isCommitted && elapsed >= commitAt + 350;
        keyHint.textContent = isCommitted ? demo.dataset.resultHint : demo.dataset.keyHint;
        buttons[scene].style.setProperty('--progress', String(Math.min(1, elapsed / current.duration)));
    }

    function selectScene(index, announce = false) {
        scene = index;
        candidates.replaceChildren(templates[index].content.cloneNode(true));
        buttons.forEach((button, i) => {
            button.setAttribute('aria-pressed', String(i === index));
            button.style.setProperty('--progress', '0');
        });
        if (announce) {
            const button = buttons[index];
            status.textContent = `${button.querySelector('[data-scene-title]').textContent}. ${button.querySelector('[data-scene-description]').textContent}`;
        }
        render();
    }

    function stopFrame() {
        if (frame !== null) cancelAnimationFrame(frame);
        frame = null;
        lastTime = null;
    }

    function schedule() {
        stopFrame();
        updateControl();
        if (playing && onScreen && !document.hidden) frame = requestAnimationFrame(tick);
    }

    function tick(time) {
        if (lastTime !== null) elapsed += time - lastTime;
        lastTime = time;
        if (elapsed >= scenes[scene].duration) {
            elapsed = 0;
            selectScene((scene + 1) % scenes.length);
        }
        render();
        frame = requestAnimationFrame(tick);
    }

    toggle.addEventListener('click', () => {
        playing = !playing;
        schedule();
    });
    demo.querySelector('[data-replay]').addEventListener('click', () => {
        elapsed = 0;
        selectScene(0, true);
        playing = true;
        schedule();
    });
    buttons.forEach((button, index) => {
        button.disabled = false;
        button.addEventListener('click', () => {
            // Manual steps stay still so visitors can read at their own pace.
            playing = false;
            elapsed = 2200;
            selectScene(index, true);
            schedule();
        });
    });
    reducedMotion.addEventListener('change', () => {
        playing = !reducedMotion.matches;
        elapsed = reducedMotion.matches ? 2200 : 0;
        render();
        schedule();
    });
    document.addEventListener('visibilitychange', schedule);
    if ('IntersectionObserver' in window) {
        new IntersectionObserver(entries => {
            onScreen = entries[0].isIntersecting;
            schedule();
        }, { threshold: 0 }).observe(demo);
    }
    demo.querySelector('[data-playback]').hidden = false;
    elapsed = reducedMotion.matches ? 2200 : 0;
    selectScene(0);
    schedule();
})();
