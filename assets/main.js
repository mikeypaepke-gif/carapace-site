    // Scroll reveal
    const observer = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) entry.target.classList.add('visible');
      });
    }, { threshold: 0.1, rootMargin: '0px 0px -50px 0px' });
    document.querySelectorAll('.reveal').forEach(el => observer.observe(el));

    // Nav background on scroll
    const nav = document.getElementById('nav');
    window.addEventListener('scroll', () => {
      if (window.scrollY > 50) {
        nav.classList.add('glass');
        nav.style.borderBottom = '1px solid rgba(255,255,255,0.04)';
      } else {
        nav.classList.remove('glass');
        nav.style.borderBottom = 'none';
      }
    }, { passive: true });

    // Close mobile menu on link click
    document.querySelectorAll('#mobile-menu a').forEach(a => {
      a.addEventListener('click', () => document.getElementById('mobile-menu').classList.add('hidden'));
    });

    // Hero Linux install command — copy button. Uses modern Clipboard
    // API with a visible "Copied!" confirmation that reverts after 2s.
    (() => {
      const btn = document.getElementById('linux-install-copy');
      if (!btn) return;
      // Copy text comes from data-copy-multiline (preferred — supports
      // the new two-command flow) or falls back to the legacy
      // #linux-install-cmd <code> element if the data attr is absent.
      const text = btn.dataset.copyMultiline ||
                   document.getElementById('linux-install-cmd')?.textContent.trim() || '';
      btn.addEventListener('click', async () => {
        try {
          await navigator.clipboard.writeText(text);
          const original = btn.textContent;
          btn.textContent = 'Copied!';
          btn.classList.add('text-[#00DCC8]');
          setTimeout(() => {
            btn.textContent = original;
            btn.classList.remove('text-[#00DCC8]');
          }, 2000);
        } catch (e) {
          // Clipboard API unavailable (http, old browser). User can
          // still select+copy the visible code blocks manually.
          btn.textContent = 'Press ⌘C';
          setTimeout(() => { btn.textContent = 'Copy both'; }, 2000);
        }
      });
    })();

    // Mac screenshot slideshow — Mac mockup was removed from the
    // hero in favor of the iPhone-only video carousel. The selector
    // lives on as a no-op so any other page that still uses
    // `.mac-slide` (none today) keeps working.
    const macSlides = document.querySelectorAll('.mac-slide');
    if (macSlides.length > 0) {
      let macCurrent = 0;
      macSlides[0].classList.add('active');
      setInterval(() => {
        macSlides[macCurrent].classList.remove('active');
        macCurrent = (macCurrent + 1) % macSlides.length;
        macSlides[macCurrent].classList.add('active');
      }, 4000);
    }

    // Hero iPhone video carousel.
    //
    // The hero's .iphone-mock contains 3 <video> elements with the
    // .iphone-slide class. Each video is muted + playsinline so iOS
    // Safari + desktop Chrome will autoplay it. We advance to the next
    // video on the active video's `ended` event so each demo gets to
    // finish naturally instead of being cut off mid-action by a fixed
    // timer.
    //
    // Vision-mode section's iPhone is a single <video autoplay loop>
    // and isn't part of this carousel — it auto-handles itself.
    const heroPhone = document.querySelector('.hero-glow .iphone-mock');
    if (heroPhone) {
      const videos = Array.from(heroPhone.querySelectorAll('video.iphone-slide'));
      if (videos.length > 0) {
        let current = 0;
        const showOnly = (idx) => {
          videos.forEach((v, i) => {
            if (i === idx) {
              v.classList.add('active');
              // currentTime=0 so the video restarts from the top
              // every time it's promoted to active. Without this,
              // a second pass through the carousel would show the
              // tail end frame for an instant before play() rewinds.
              try { v.currentTime = 0; } catch {}
              const p = v.play();
              if (p && typeof p.catch === 'function') {
                // Autoplay can reject on first paint if the page
                // hasn't received a user interaction yet (rare on
                // muted+playsinline, but happens). Swallow — the
                // browser will retry on the next interaction.
                p.catch(() => {});
              }
            } else {
              v.classList.remove('active');
              try { v.pause(); } catch {}
            }
          });
        };

        // Wire the `ended` listener once. We let `loop` stay on the
        // <video> as a safety belt for the LAST clip in the carousel
        // — if the JS errors out, at least the video keeps playing.
        // For all other clips the `ended` handler clears active
        // BEFORE the loop kicks back to frame 0 of the same video,
        // so visually the user sees a clean transition to the next
        // video, not a re-loop of the current one.
        videos.forEach((v, i) => {
          v.addEventListener('ended', () => {
            // Only the active video's `ended` should drive the rotation.
            if (i !== current) return;
            current = (current + 1) % videos.length;
            showOnly(current);
          });
        });

        // Kick off with video 0 active.
        showOnly(0);

        // Defensive: if the active video stalls (network hiccup or
        // codec issue), fall back to a 25s max per slide. 25s safely
        // exceeds the longest clip (35s? no — 13/15/35), so for the
        // 35s clip we bump to 40s so it always completes naturally.
        // For shorter clips the `ended` event fires first and the
        // timer becomes a no-op for that pass.
        setInterval(() => {
          const v = videos[current];
          if (!v) return;
          if (v.paused || v.readyState < 2) {
            current = (current + 1) % videos.length;
            showOnly(current);
          }
        }, 40000);
      }
    }

    // ─────────────────────────────────────────────────────────────────
    // Lazy-loaded marketing clips (data-src + preload="none").
    // Covers the "In the wild" strip (.wild-clip — Patrick + sprinkler)
    // AND the Glasses Beta founder clip (.glasses-clip — Mike in Ray-
    // Bans). Both share the same IO behavior: attach src on scroll-in,
    // pause on scroll-out, so bandwidth is bounded to what's visible.
    // ─────────────────────────────────────────────────────────────────
    {
      const lazyClips = document.querySelectorAll('video.wild-clip, video.glasses-clip');
      if (lazyClips.length && 'IntersectionObserver' in window) {
        const io = new IntersectionObserver((entries) => {
          for (const ent of entries) {
            const v = ent.target;
            if (ent.isIntersecting) {
              if (!v.src && v.dataset.src) {
                v.src = v.dataset.src;
              }
              const p = v.play();
              if (p && typeof p.catch === 'function') p.catch(() => {});
            } else {
              try { v.pause(); } catch {}
            }
          }
        }, { rootMargin: '100px 0px', threshold: 0.25 });
        lazyClips.forEach((v) => io.observe(v));
      } else {
        // No IO support — attach + play eagerly. Same behavior as the
        // old demos (cheap on modern browsers; this branch is only hit
        // by ancient stuff like IE).
        lazyClips.forEach((v) => {
          if (v.dataset.src) v.src = v.dataset.src;
          const p = v.play();
          if (p && typeof p.catch === 'function') p.catch(() => {});
        });
      }
    }

    // Scroll-bound rotation on the Meta-beta glasses SVG.
    // Ties rotation to viewport progress so they spin as the user scrolls
    // past the section — same effect-feel as eyewear product pages, but
    // on our own original illustration so there's no IP leakage.
    (() => {
      const glasses = document.getElementById('beta-glasses');
      const stage = document.getElementById('beta-glasses-stage');
      if (!glasses || !stage) return;
      // Respect users who've asked their OS to reduce motion.
      if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

      let ticking = false;
      let inView = false;

      const update = () => {
        ticking = false;
        if (!inView) return;
        const rect = stage.getBoundingClientRect();
        const vh = window.innerHeight || document.documentElement.clientHeight;
        // progress: 0 when the stage is just entering the bottom of the
        // viewport, 1 when it's fully past the top.
        const progress = Math.max(0, Math.min(1, (vh - rect.top) / (vh + rect.height)));
        // 540° rotateY across the scroll range = 1.5 full spins. Subtle
        // rotateX tilt peaks in the middle for a 3D "coming toward you"
        // feel without going full disorienting.
        const rotY = progress * 540;
        const rotX = Math.sin(progress * Math.PI) * 12;
        glasses.style.transform = `rotateX(${rotX}deg) rotateY(${rotY}deg)`;
      };

      const onScroll = () => {
        if (!ticking) {
          requestAnimationFrame(update);
          ticking = true;
        }
      };

      // Only attach scroll work when the section is near the viewport.
      const io = new IntersectionObserver((entries) => {
        for (const e of entries) {
          inView = e.isIntersecting;
          if (inView) update();
        }
      }, { rootMargin: '200px 0px' });
      io.observe(stage);

      window.addEventListener('scroll', onScroll, { passive: true });
      window.addEventListener('resize', onScroll, { passive: true });
      update();
    })();
