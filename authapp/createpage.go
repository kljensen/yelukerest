package main

// A plain link that creates a repository (issue #399, UX review).
//
//	GET /auth/assignments/{slug}/repository/create
//
// Assignment text needs something a student can click, the way a GitHub
// Classroom invitation link is clicked. This page is that link: it POSTs to
// the create route with the browser's session, exactly as the assignment
// page's button does, and then sends the browser to the assignment page,
// which shows whatever state resulted (ready, copying, needs_github_link,
// needs_org_join, or an error). There is no second way to create a
// repository here: the POST is the same one, with the same same-origin
// check, limits, and rules. This is a convenience, not the primary path,
// and docs/github-provisioning.md says so.

import (
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"

	"github.com/alexedwards/scs/v2"
)

const (
	repositoryCreatePagePath = "/auth/assignments/{slug}/repository/create"
	// repositoryCreateScriptPath is the page's script, external because
	// Caddy's CSP forbids inline ones. Not under /auth/assignments/{slug}/,
	// so it is one route rather than one per assignment.
	repositoryCreateScriptPath = "/auth/assignments/repository-create.js"
)

// repositoryCreatePageTemplate follows the join landing page: a form the
// script attaches to and submits on load, a status line, and the noscript
// note for the student without JavaScript.
var repositoryCreatePageTemplate = template.Must(template.New("create").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Creating your repository</title>
</head>
<body>
<main>
<h1>Creating your repository</h1>
<p>Your repository for <strong>{{.Slug}}</strong> is being requested. You will be taken to the assignment page, which shows its status.</p>
<form id="create" method="POST" action="{{.Action}}" data-return="{{.ReturnPath}}">
<button type="submit">Create repository</button>
</form>
<p id="status"><noscript>This page needs JavaScript to continue. <a href="{{.ReturnPath}}">Open the assignment page</a> and use the button there instead.</noscript></p>
<script src="{{.ScriptPath}}"></script>
</main>
</body>
</html>
`))

// repositoryCreateScript posts once and follows to the assignment page
// whatever the answer was, since the assignment page reads the state
// itself. Only a failure to reach the site at all keeps the student here,
// with the button for a retry.
const repositoryCreateScript = `(function () {
  var form = document.getElementById("create");
  var status = document.getElementById("status");
  var busy = false;
  function create(event) {
    if (event) { event.preventDefault(); }
    if (busy) { return; }
    busy = true;
    status.textContent = "Contacting the course site…";
    fetch(form.action, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: "{}"
    }).then(function () {
      window.location.assign(form.getAttribute("data-return"));
    }).catch(function () {
      status.textContent = "Could not reach the course site. Use the button to try again.";
      busy = false;
    });
  }
  form.addEventListener("submit", create);
  create();
})();
`

// registerRepositoryCreatePage adds the page and its script. Called from
// registerProvisioningRoutes, so both are absent when provisioning is.
func registerRepositoryCreatePage(mux *http.ServeMux, sessions *scs.SessionManager) {
	mux.HandleFunc("GET "+repositoryCreatePagePath, func(w http.ResponseWriter, r *http.Request) {
		setLandingPageHeaders(w)
		slug := r.PathValue("slug")
		if !assignmentSlugPattern.MatchString(slug) {
			http.Error(w, "Malformed assignment slug", http.StatusBadRequest)
			return
		}
		pagePath := "/auth/assignments/" + url.PathEscape(slug) + "/repository/create"
		if sessions.GetString(r.Context(), "netid") == "" {
			http.Redirect(w, r, githubJoinLoginPath+"?"+url.Values{"next": {safeRedirectPath(pagePath)}}.Encode(), http.StatusFound)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		view := struct{ Slug, Action, ReturnPath, ScriptPath string }{
			Slug:       slug,
			Action:     "/auth/assignments/" + url.PathEscape(slug) + "/repository",
			ReturnPath: "/#/assignments/" + url.PathEscape(slug),
			ScriptPath: repositoryCreateScriptPath,
		}
		if err := repositoryCreatePageTemplate.Execute(w, view); err != nil {
			log.Printf("provisioning: rendering the create page: %v", err)
		}
	})
	mux.HandleFunc("GET "+repositoryCreateScriptPath, func(w http.ResponseWriter, r *http.Request) {
		setNoStoreHeaders(w)
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		_, _ = io.WriteString(w, repositoryCreateScript)
	})
}
