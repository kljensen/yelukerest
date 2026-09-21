// The repositories page's script (served as /auth/repositories.js; see
// repositoriespage.go for what it does and why it posts only on a click).
(function () {
  var POLL_INTERVAL_MS = 3000;
  var POLL_LIMIT_MS = 120000;
  var JSON_HEADERS = { "Accept": "application/json" };

  // nextPollDelay is how long to wait before polling again: the interval,
  // or a longer Retry-After the server asked for. It is -1 when that wait
  // would end past the deadline, which is when polling stops and the page
  // offers Check again instead -- so a long Retry-After cannot schedule a
  // poll beyond the two minutes the page promised.
  function nextPollDelay(nowMs, deadlineMs, retryAfterMs) {
    var delay = Math.max(POLL_INTERVAL_MS, retryAfterMs > 0 ? retryAfterMs : 0);
    return nowMs + delay > deadlineMs ? -1 : delay;
  }

  // Under Bun (static/repositories.test.js) only the arithmetic is wanted;
  // a browser has no module and carries on to the page.
  if (typeof module !== "undefined" && module.exports) {
    module.exports = { nextPollDelay: nextPollDelay, POLL_INTERVAL_MS: POLL_INTERVAL_MS, POLL_LIMIT_MS: POLL_LIMIT_MS };
    return;
  }

  function link(href) {
    var a = document.createElement("a");
    a.href = href;
    a.textContent = href;
    return a;
  }

  function messageOf(row) {
    var status = row.querySelector(".status");
    var message = status.querySelector(".message");
    if (!message) {
      message = document.createElement("p");
      message.className = "message";
      status.insertBefore(message, status.firstChild);
    }
    while (message.firstChild) { message.removeChild(message.firstChild); }
    return message;
  }

  function setForm(row, keep, label) {
    var form = row.querySelector("form.create");
    if (!form) { return; }
    if (!keep) { form.parentNode.removeChild(form); return; }
    var button = form.querySelector("button");
    button.disabled = false;
    button.textContent = label;
  }

  function addRepository(row, url) {
    var list = document.getElementById("repository-list");
    var slug = row.getAttribute("data-slug");
    for (var i = 0; i < list.children.length; i++) {
      if (list.children[i].getAttribute("data-slug") === slug) { return; }
    }
    var item = document.createElement("li");
    item.setAttribute("data-slug", slug);
    item.appendChild(link(url));
    item.appendChild(document.createTextNode(" — " + row.querySelector(".label strong").textContent));
    list.appendChild(item);
    var none = document.getElementById("no-repositories");
    if (none) { none.parentNode.removeChild(none); }
  }

  function render(row, body, retryAfterMs) {
    var message = messageOf(row);
    var state = body && body.state;
    row.setAttribute("data-state", state || "");
    if (state === "ready") {
      message.appendChild(document.createTextNode("Ready: "));
      message.appendChild(link(body.repo_url));
      setForm(row, false);
      addRepository(row, body.repo_url);
      return;
    }
    if (state === "copying") {
      message.appendChild(document.createTextNode("Preparing your repository… "));
      message.appendChild(link(body.repo_url));
      setForm(row, false);
      schedulePoll(row, retryAfterMs);
      return;
    }
    if (state === "needs_github_link" || state === "needs_org_join") {
      message.appendChild(document.createTextNode(state === "needs_github_link"
        ? "Connect your GitHub account first. "
        : "Your GitHub account is not in the course organization yet. "));
      if (body.join_url) {
        var join = document.createElement("a");
        join.href = body.join_url;
        join.textContent = "Connect your GitHub account";
        message.appendChild(join);
      } else {
        message.appendChild(document.createTextNode(state === "needs_github_link"
          ? "Ask the course staff to record your GitHub username."
          : "Accept the organization's invitation, then try again."));
      }
      setForm(row, true, "Try again");
      return;
    }
    var code = (body && body.error && body.error.code) || "unknown";
    var retryable = !!(body && body.error && body.error.retryable);
    message.appendChild(document.createTextNode("Could not create the repository (" + code + ")." +
      (retryable ? "" : " Contact the course staff.")));
    setForm(row, true, "Try again");
  }

  function parse(response) {
    var retryAfter = Number(response.headers.get("Retry-After")) * 1000;
    return response.json().then(function (body) {
      return { body: body, retryAfterMs: retryAfter > 0 ? retryAfter : 0 };
    });
  }

  function checkAgain(row) {
    var message = messageOf(row);
    message.appendChild(document.createTextNode("Still preparing. "));
    var button = document.createElement("button");
    button.type = "button";
    button.textContent = "Check again";
    button.addEventListener("click", function () {
      button.disabled = true;
      row.pollDeadline = Date.now() + POLL_LIMIT_MS;
      poll(row);
    });
    message.appendChild(button);
  }

  function schedulePoll(row, retryAfterMs) {
    if (!row.pollDeadline) { row.pollDeadline = Date.now() + POLL_LIMIT_MS; }
    var delay = nextPollDelay(Date.now(), row.pollDeadline, retryAfterMs);
    if (delay < 0) { checkAgain(row); return; }
    if (row.pollTimer) { clearTimeout(row.pollTimer); }
    row.pollTimer = setTimeout(function () { poll(row); }, delay);
  }

  function poll(row) {
    row.pollTimer = null;
    fetch(row.getAttribute("data-action"), { method: "GET", credentials: "same-origin", headers: JSON_HEADERS })
      .then(parse)
      .then(function (result) { render(row, result.body, result.retryAfterMs); })
      .catch(function () { checkAgain(row); });
  }

  var rows = document.querySelectorAll("li.template");
  for (var i = 0; i < rows.length; i++) {
    (function (row) {
      if (row.getAttribute("data-state") === "copying") { schedulePoll(row, 0); }
      var form = row.querySelector("form.create");
      if (!form) { return; }
      form.addEventListener("submit", function (event) {
        event.preventDefault();
        var button = form.querySelector("button");
        if (button.disabled) { return; }
        button.disabled = true;
        messageOf(row).textContent = "Contacting the course site…";
        fetch(form.action, {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/json", "Accept": "application/json" },
          body: "{}"
        }).then(parse).then(function (result) {
          row.pollDeadline = Date.now() + POLL_LIMIT_MS;
          render(row, result.body, result.retryAfterMs);
        }).catch(function () {
          messageOf(row).textContent = "Could not reach the course site. Use the button to try again.";
          button.disabled = false;
        });
      });
    })(rows[i]);
  }
})();
