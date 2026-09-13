/* flakedoc's search.
 *
 * Plain browser JavaScript against one JSON index, because there is no server
 * to ask and no bundler in the pipeline. The index is fetched relative to the
 * page -- the site is published under a path prefix, so nothing here may build
 * a URL that starts with "/".
 *
 * Two consumers, one index and one matcher: the options page's full result
 * list, and the small drop-down in the header that searches everything.
 */
(function () {
  "use strict";

  var ROOT = document.body.getAttribute("data-root") || "";
  var MAX_OPTION_RESULTS = 100;
  var MAX_SITE_RESULTS = 12;

  var indexPromise = null;

  function loadIndex() {
    if (indexPromise) return indexPromise;
    indexPromise = fetch(ROOT + "search-index.json")
      .then(function (response) {
        if (!response.ok) throw new Error("search index: " + response.status);
        return response.json();
      })
      .then(function (data) {
        return {
          sets: data.sets || [],
          items: data.items || [],
          pages: data.pages || [],
        };
      })
      .catch(function (error) {
        console.error("flakedoc: could not load the search index", error);
        return { sets: [], items: [], pages: [] };
      });
    return indexPromise;
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"']/g, function (c) {
      return {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      }[c];
    });
  }

  /* Score one candidate against a normalized query.
   *
   * Tiers rather than a blended number: a reader typing "audio" wants
   * stewos.audio.enable before anything that merely contains those letters in
   * order, and no weighting of a fuzzy match will reliably put it there. */
  function score(haystack, needle) {
    if (!needle) return [4, 0];

    var index = haystack.indexOf(needle);
    if (index === 0) {
      return haystack.length === needle.length ? [0, 0] : [1, 0];
    }
    if (index > 0) {
      /* A match right after a dot starts a component, which reads as a
       * stronger hit than one in the middle of a word. */
      var boundary = haystack[index - 1] === "." || haystack[index - 1] === "-";
      return [boundary ? 2 : 3, index];
    }

    /* Subsequence fallback: "sdwp" finds stewos.desktop.wallpaper. */
    var h = 0;
    var n = 0;
    var first = -1;
    while (h < haystack.length && n < needle.length) {
      if (haystack[h] === needle[n]) {
        if (first < 0) first = h;
        n++;
      }
      h++;
    }
    if (n === needle.length) return [5, first < 0 ? 0 : first];
    return null;
  }

  function compare(a, b) {
    if (a.tier !== b.tier) return a.tier - b.tier;
    if (a.position !== b.position) return a.position - b.position;
    if (a.text.length !== b.text.length) return a.text.length - b.text.length;
    return a.text < b.text ? -1 : a.text > b.text ? 1 : 0;
  }

  function marked(text, needle) {
    if (!needle) return escapeHtml(text);
    var index = text.toLowerCase().indexOf(needle);
    if (index < 0) return escapeHtml(text);
    return (
      escapeHtml(text.slice(0, index)) +
      "<mark>" +
      escapeHtml(text.slice(index, index + needle.length)) +
      "</mark>" +
      escapeHtml(text.slice(index + needle.length))
    );
  }

  /* ------------------------------------------------------- options page */

  function setupOptionSearch() {
    var container = document.querySelector(".option-search");
    if (!container) return;

    var input = document.getElementById("option-search");
    var facets = document.getElementById("option-facets");
    var results = document.getElementById("option-results");
    var status = document.getElementById("option-status");
    if (!input || !results) return;

    var index = null;

    function enabledSets() {
      if (!facets) return null;
      var boxes = facets.querySelectorAll("input[type=checkbox]");
      var allowed = {};
      var any = false;
      for (var i = 0; i < boxes.length; i++) {
        if (boxes[i].checked) {
          allowed[boxes[i].value] = true;
          any = true;
        }
      }
      /* Unchecking everything means "no filter" rather than "no results",
       * which is the only reading that leaves the page usable. */
      return any ? allowed : null;
    }

    function render() {
      if (!index) return;

      var query = input.value.trim().toLowerCase();
      var allowed = enabledSets();
      var matches = [];

      for (var i = 0; i < index.items.length; i++) {
        var item = index.items[i];
        var set = index.sets[item[1]];
        if (allowed && set && !allowed[set.id]) continue;

        var s = score(item[0].toLowerCase(), query);
        if (!s) continue;
        matches.push({ item: item, set: set, tier: s[0], position: s[1], text: item[0] });
      }

      matches.sort(compare);
      var shown = matches.slice(0, MAX_OPTION_RESULTS);

      var html = "";
      for (var j = 0; j < shown.length; j++) {
        var m = shown[j];
        var setTitle = m.set ? m.set.title : "";
        html +=
          '<li><a href="' +
          escapeHtml(ROOT + m.item[4]) +
          '"><span class="r-name">' +
          marked(m.item[0], query) +
          "</span>" +
          (m.item[2] ? '<span class="r-type">' + escapeHtml(m.item[2]) + "</span>" : "") +
          (setTitle ? '<span class="r-type">' + escapeHtml(setTitle) + "</span>" : "") +
          (m.item[3] ? '<span class="r-desc">' + escapeHtml(m.item[3]) + "</span>" : "") +
          "</a></li>";
      }
      results.innerHTML = html;

      if (status) {
        if (!matches.length) {
          status.textContent = query
            ? 'No options match "' + input.value.trim() + '".'
            : "No options.";
        } else if (matches.length > shown.length) {
          status.textContent =
            "Showing " + shown.length + " of " + matches.length + " matching options.";
        } else {
          status.textContent =
            matches.length + (matches.length === 1 ? " option." : " options.");
        }
      }

      var url = new URL(window.location.href);
      if (query) {
        url.searchParams.set("q", input.value.trim());
      } else {
        url.searchParams.delete("q");
      }
      window.history.replaceState(null, "", url.toString());
    }

    var params = new URLSearchParams(window.location.search);
    var initial = params.get("q");
    if (initial) input.value = initial;

    if (status) status.textContent = "Loading options…";

    loadIndex().then(function (data) {
      index = data;
      render();
    });

    input.addEventListener("input", render);
    if (facets) facets.addEventListener("change", render);
  }

  /* ----------------------------------------------------- header drop-down */

  function setupSiteSearch() {
    var input = document.getElementById("site-search");
    var panel = document.getElementById("site-search-results");
    if (!input || !panel) return;

    var index = null;
    var selected = -1;

    function entries() {
      var all = [];
      var i;
      for (i = 0; i < index.items.length; i++) {
        var set = index.sets[index.items[i][1]];
        all.push({
          text: index.items[i][0],
          meta: set ? set.title + " option" : "option",
          url: index.items[i][4],
        });
      }
      for (i = 0; i < index.pages.length; i++) {
        all.push({
          text: index.pages[i][0],
          meta: index.pages[i][1],
          url: index.pages[i][3],
        });
      }
      return all;
    }

    function close() {
      panel.hidden = true;
      panel.innerHTML = "";
      selected = -1;
    }

    function render() {
      var query = input.value.trim().toLowerCase();
      if (!query || !index) {
        close();
        return;
      }

      var matches = [];
      var all = entries();
      for (var i = 0; i < all.length; i++) {
        var s = score(all[i].text.toLowerCase(), query);
        if (!s) continue;
        matches.push({
          text: all[i].text,
          meta: all[i].meta,
          url: all[i].url,
          tier: s[0],
          position: s[1],
        });
      }
      matches.sort(compare);
      matches = matches.slice(0, MAX_SITE_RESULTS);

      if (!matches.length) {
        panel.innerHTML = '<a class="r-meta">No matches.</a>';
        panel.hidden = false;
        return;
      }

      var html = "";
      for (var j = 0; j < matches.length; j++) {
        html +=
          '<a href="' +
          escapeHtml(ROOT + matches[j].url) +
          '"><span class="r-name">' +
          marked(matches[j].text, query) +
          '</span><span class="r-meta">' +
          escapeHtml(matches[j].meta) +
          "</span></a>";
      }
      panel.innerHTML = html;
      panel.hidden = false;
      selected = -1;
    }

    function move(delta) {
      var links = panel.querySelectorAll("a[href]");
      if (!links.length) return;
      if (selected >= 0 && links[selected]) links[selected].classList.remove("selected");
      selected = (selected + delta + links.length) % links.length;
      links[selected].classList.add("selected");
      links[selected].scrollIntoView({ block: "nearest" });
    }

    input.addEventListener("focus", function () {
      loadIndex().then(function (data) {
        index = data;
        if (document.activeElement === input) render();
      });
    });

    input.addEventListener("input", render);

    input.addEventListener("keydown", function (event) {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        move(1);
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        move(-1);
      } else if (event.key === "Enter") {
        var links = panel.querySelectorAll("a[href]");
        if (selected >= 0 && links[selected]) {
          event.preventDefault();
          window.location.href = links[selected].getAttribute("href");
        }
      } else if (event.key === "Escape") {
        close();
        input.blur();
      }
    });

    document.addEventListener("click", function (event) {
      if (!panel.contains(event.target) && event.target !== input) close();
    });
  }

  /* ------------------------------------------------------------- chrome */

  function setupNavToggle() {
    var button = document.querySelector(".nav-toggle");
    var sidebar = document.getElementById("sidebar");
    if (!button || !sidebar) return;
    button.addEventListener("click", function () {
      var open = sidebar.classList.toggle("open");
      button.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  function setupSlashKey() {
    document.addEventListener("keydown", function (event) {
      if (event.key !== "/" || event.ctrlKey || event.metaKey || event.altKey) return;
      var active = document.activeElement;
      if (
        active &&
        (active.tagName === "INPUT" ||
          active.tagName === "TEXTAREA" ||
          active.isContentEditable)
      ) {
        return;
      }
      var target =
        document.getElementById("option-search") || document.getElementById("site-search");
      if (!target) return;
      event.preventDefault();
      target.focus();
      target.select();
    });
  }

  setupNavToggle();
  setupSlashKey();
  setupOptionSearch();
  setupSiteSearch();
})();
