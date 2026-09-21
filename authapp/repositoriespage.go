package main

// The repositories page (ADR 0006, decoupled from submissions 2026-09-21).
//
//	GET /auth/repositories      the page
//	GET /auth/repositories.js   its script
//
// A repository is a resource with a page of its own, not a step of an
// assignment. The page shows the student three things: whether a GitHub
// account is connected (and the way to connect one, the join flow in
// join.go), the templates they may create a repository from, each with a
// Create button or its current state, and the repositories they have.
// It is server-rendered from the database alone -- rendering it never
// calls GitHub and never claims an attempt -- and it works without the
// script: the Create form posts to the create route, which sends the
// browser back here with the outcome in the query.
//
// The script does two things on top. It submits Create by fetch, so the
// row re-renders from the JSON reply instead of the page reloading, and it
// polls the status route every three seconds while a repository is being
// copied, for at most two minutes, after which it offers a Check again
// button. The POST happens on the click and never on load: the page is
// reachable by a plain GET from anywhere, and a script that posted as soon
// as it rendered would turn any cross-site link here into a repository
// creation, because the fetch would originate from our own document and
// pass the same-origin check. The click is what makes it the student's
// decision. The script is external because Caddy's CSP forbids inline
// ones.

import (
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

const (
	repositoriesScriptPath = "/auth/repositories.js"

	// The row states the page renders from the rows it read. The states
	// the create route answers with (ready, copying, needs_github_link,
	// needs_org_join) are the script's, from the JSON; these two are what
	// an attempt row alone can say about a repository that is not there.
	repositoryRowFailed      = "failed"
	repositoryRowInterrupted = "interrupted"
)

// repositoriesMarkerPattern bounds the two query values the page echoes
// back as a notice: the join marker and the create route's result. Both
// are codes this program minted, so anything outside the shape is dropped.
var repositoriesMarkerPattern = regexp.MustCompile(`^[a-z_]+(:[a-z_]+)?$`)

// repositoriesPageView is what the template renders.
type repositoriesPageView struct {
	NetID          string
	IsStudent      bool
	GitHubLogin    string
	GitHubVerified bool
	// JoinURL is the join landing page, or "" when the join flow is not
	// configured, in which case the student is told to accept the
	// organization's invitation instead.
	JoinURL string
	// Notice is the one-line notice for a github_join marker or a form
	// post's result; "" for none.
	Notice       string
	Templates    []repositoriesPageRow
	Repositories []provisioningRepository
	ScriptPath   string
	Stylesheet   string
}

// repositoriesPageRow is one template row: the template plus what is
// known about the caller's repository from it.
type repositoriesPageRow struct {
	Slug        string
	Label       string
	Description string
	IsTeam      bool
	// State is "" when nothing has been asked for (show Create), ready or
	// copying when a repository is recorded, failed or interrupted when an
	// attempt is and no repository is.
	State     string
	RepoURL   string
	ErrorCode string
	Action    string
}

var repositoriesPageTemplate = template.Must(template.New("repositories").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Your repositories</title>
<link rel="stylesheet" href="{{.Stylesheet}}">
</head>
<body>
<main class="consent">
<h1>Repositories</h1>
<p class="note">Signed in as {{.NetID}}</p>
{{if .Notice}}<p class="notice" id="notice">{{.Notice}}</p>{{end}}
<section id="account">
<h2>GitHub account</h2>
{{if .GitHubLogin}}
<p>Connected as <strong>{{.GitHubLogin}}</strong>{{if .GitHubVerified}} <span class="badge">verified</span>{{end}}.</p>
{{if and .JoinURL (not .GitHubVerified)}}
<form method="GET" action="{{.JoinURL}}"><input type="hidden" name="next" value="` + repositoriesPagePath + `"><button type="submit">Verify it and join the course organization</button></form>
{{end}}
{{else if .JoinURL}}
<p>No GitHub account is connected yet. Connecting one confirms which account is yours and adds it to the course organization; the course gets no access to your repositories.</p>
<form method="GET" action="{{.JoinURL}}"><input type="hidden" name="next" value="` + repositoriesPagePath + `"><button type="submit">Connect your GitHub account</button></form>
{{else}}
<p>No GitHub account is connected yet. Ask the course staff to record your GitHub username, and accept the invitation to the course organization when it arrives.</p>
{{end}}
</section>
<section id="templates">
<h2>Create a repository</h2>
{{if not .IsStudent}}<p class="note">Only students create repositories here.</p>{{end}}
{{if .Templates}}
<ul class="scopelist">
{{range .Templates}}
<li class="template" data-slug="{{.Slug}}" data-state="{{.State}}" data-action="{{.Action}}">
<div class="label"><strong>{{.Label}}</strong>{{if .IsTeam}} <span class="badge">team</span>{{end}}</div>
{{if .Description}}<span class="desc">{{.Description}}</span>{{end}}
<div class="status">
{{if eq .State "ready"}}<p class="message">Ready: <a href="{{.RepoURL}}">{{.RepoURL}}</a></p>
{{else if eq .State "copying"}}<p class="message">Preparing your repository… <a href="{{.RepoURL}}">{{.RepoURL}}</a></p>
{{else}}
{{if eq .State "failed"}}<p class="message">Could not create it last time ({{.ErrorCode}}).</p>
{{else if eq .State "interrupted"}}<p class="message">A previous attempt was interrupted.</p>
{{else}}<p class="message"></p>{{end}}
{{if $.IsStudent}}<form class="create" method="POST" action="{{.Action}}"><button type="submit">{{if .State}}Try again{{else}}Create{{end}}</button></form>{{end}}
{{end}}
</div>
</li>
{{end}}
</ul>
{{else}}
<p>No templates are available to you right now.</p>
{{end}}
</section>
<section id="repositories">
<h2>Your repositories</h2>
<ul id="repository-list">
{{range .Repositories}}
<li data-slug="{{.TemplateSlug}}"><a href="{{.RepoURL}}">{{.ProviderFullName}}</a> — {{.Label}}</li>
{{end}}
</ul>
{{if not .Repositories}}<p id="no-repositories">None yet.</p>{{end}}
<p class="note">Paste a repository's address into the assignment that asks for it.</p>
</section>
<noscript><p class="note">Without JavaScript the Create button still works; the page reloads with the outcome.</p></noscript>
<script src="{{.ScriptPath}}"></script>
</main>
</body>
</html>
`))

// repositoriesScript: Create by fetch on the click (only then, see the
// file comment), the row re-rendered from the JSON, and polling while
// copying. Every element is built with textContent, never markup, so
// nothing from a reply is interpreted as HTML.
const repositoriesScript = `(function () {
  var POLL_INTERVAL_MS = 3000;
  var POLL_LIMIT_MS = 120000;
  var JSON_HEADERS = { "Accept": "application/json" };

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
      row.pollStartedAt = Date.now();
      poll(row);
    });
    message.appendChild(button);
  }

  function schedulePoll(row, retryAfterMs) {
    if (!row.pollStartedAt) { row.pollStartedAt = Date.now(); }
    if (Date.now() - row.pollStartedAt > POLL_LIMIT_MS) { checkAgain(row); return; }
    if (row.pollTimer) { clearTimeout(row.pollTimer); }
    row.pollTimer = setTimeout(function () { poll(row); }, Math.max(POLL_INTERVAL_MS, retryAfterMs || 0));
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
          row.pollStartedAt = Date.now();
          render(row, result.body, result.retryAfterMs);
        }).catch(function () {
          messageOf(row).textContent = "Could not reach the course site. Use the button to try again.";
          button.disabled = false;
        });
      });
    })(rows[i]);
  }
})();
`

// servePage renders the page. A signed-out visitor is sent through login
// and back. Everything on it is read from the database: the caller's row
// as the service (for the GitHub fields, which the app role may read), and
// the templates, attempts, and repositories as the student, under
// row-level security.
func (h *provisioningHandler) servePage(w http.ResponseWriter, r *http.Request) {
	setLandingPageHeaders(w)
	ctx := r.Context()
	netID := h.sessions.GetString(ctx, "netid")
	if netID == "" {
		http.Redirect(w, r, githubJoinLoginPath+"?"+url.Values{"next": {repositoriesPagePath}}.Encode(), http.StatusFound)
		return
	}
	caller, reply := h.lookupUser(ctx, netID)
	if reply != nil {
		h.pageError(w, reply)
		return
	}
	info, reply := h.studentReads(netID)
	if reply != nil {
		h.pageError(w, reply)
		return
	}
	templates, reply := h.readTemplates(ctx, info.JWT, "")
	if reply != nil {
		h.pageError(w, reply)
		return
	}
	attempts, reply := h.readAttempts(ctx, info.JWT, "")
	if reply != nil {
		h.pageError(w, reply)
		return
	}
	repositories, reply := h.readRepositories(ctx, info.JWT, "")
	if reply != nil {
		h.pageError(w, reply)
		return
	}

	view := repositoriesPageView{
		NetID:          netID,
		IsStudent:      info.Role == "student",
		GitHubLogin:    caller.GitHubLogin,
		GitHubVerified: caller.GitHubVerifiedAt != nil,
		Notice:         repositoriesNotice(r.URL.Query()),
		Repositories:   repositories,
		ScriptPath:     repositoriesScriptPath,
		Stylesheet:     oauthStylesheetPath,
	}
	if h.github.join != nil {
		view.JoinURL = githubJoinLandingPath
	}
	for _, t := range templates {
		// A team template is offered only to a student on a team; the
		// claim RPC would refuse it with no_team, and a button that can
		// only be refused is not one to show.
		if t.IsTeam && info.TeamNickname == "" {
			continue
		}
		view.Templates = append(view.Templates, repositoryRowOf(t, attempts, repositories))
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := repositoriesPageTemplate.Execute(w, view); err != nil {
		log.Printf("provisioning: rendering the repositories page: %v", err)
	}
}

// repositoryRowOf derives a template row's state from the rows read, with
// no GitHub call: a recorded repository is ready once its attempt says so
// (or has no attempt, as the old tooling's rows do) and copying until
// then, which the script polls; an attempt with no repository is a failed
// or interrupted one, both answered with a button that repeats the POST.
func repositoryRowOf(t provisioningTemplate, attempts []provisioningAttempt, repositories []provisioningRepository) repositoriesPageRow {
	row := repositoriesPageRow{
		Slug:        t.Slug,
		Label:       t.Label,
		Description: t.Description,
		IsTeam:      t.IsTeam,
		Action:      repositoriesPagePath + "/" + url.PathEscape(t.Slug),
	}
	var attempt *provisioningAttempt
	for i := range attempts {
		if attempts[i].TemplateSlug == t.Slug {
			attempt = &attempts[i]
			break
		}
	}
	for _, repo := range repositories {
		if repo.TemplateSlug != t.Slug {
			continue
		}
		row.RepoURL = repo.RepoURL
		if row.RepoURL == "" {
			row.RepoURL = "https://github.com/" + repo.ProviderFullName
		}
		if attempt == nil || attempt.ReadyAt != nil {
			row.State = repositoryStateReady
		} else {
			row.State = repositoryStateCopying
		}
		return row
	}
	if attempt == nil {
		return row
	}
	switch attempt.Stage {
	case provisioningStageFinalized:
		row.State = repositoryStateCopying
		row.RepoURL = "https://github.com/" + attempt.ProviderFullName
	case provisioningStageFailed:
		row.State = repositoryRowFailed
		row.ErrorCode = attempt.ErrorCode
		if row.ErrorCode == "" {
			row.ErrorCode = "provisioning_failed"
		}
	default:
		row.State = repositoryRowInterrupted
	}
	return row
}

// repositoriesNotice is the one line the page shows for what just
// happened: the join callback's github_join marker, or the create route's
// result after a form post. Both values are codes minted by this program,
// checked for shape and mapped to text; nothing from the query reaches
// the page unmapped except a code, escaped.
func repositoriesNotice(query url.Values) string {
	if marker := query.Get("github_join"); marker != "" {
		if !repositoriesMarkerPattern.MatchString(marker) {
			return ""
		}
		switch marker {
		case joinMarkerOK:
			return "Your GitHub account is connected and in the course organization."
		case joinMarkerDenied:
			return "You cancelled the GitHub authorization; nothing changed."
		}
		code := strings.TrimPrefix(marker, "error:")
		switch code {
		case joinErrAppMisconfigured, joinErrCredentialRejected, joinErrIdentityTaken, joinErrIdentityLocked:
			return "Connecting your GitHub account failed (" + code + "). Contact the course staff."
		}
		return "Connecting your GitHub account failed (" + code + "). Try again in a moment."
	}
	result := query.Get("result")
	slug := query.Get("template")
	if result == "" || !repositoriesMarkerPattern.MatchString(result) || !templateSlugPattern.MatchString(slug) {
		return ""
	}
	switch result {
	case repositoryStateReady:
		return slug + ": your repository is ready."
	case repositoryStateCopying:
		return slug + ": your repository is being prepared; reload in a moment."
	case repositoryStateNeedsGitHubLink:
		return slug + ": connect your GitHub account first (above), then try again."
	case repositoryStateNeedsOrgJoin:
		return slug + ": your GitHub account is not in the course organization yet (above)."
	}
	return slug + ": could not create the repository (" + result + ")."
}

// pageError answers the page with the reply's status and code as text.
// The page has nothing to render without its reads, and the code is what
// the JSON routes would have said.
func (h *provisioningHandler) pageError(w http.ResponseWriter, reply *provisioningReply) {
	http.Error(w, "Could not load the repositories page ("+reply.code+").", reply.status)
}

func serveRepositoriesScript(w http.ResponseWriter, r *http.Request) {
	setNoStoreHeaders(w)
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = io.WriteString(w, repositoriesScript)
}
