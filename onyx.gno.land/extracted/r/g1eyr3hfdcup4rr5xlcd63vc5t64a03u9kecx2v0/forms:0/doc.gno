// Package forms is a Google-Forms-shaped questionnaire realm: publish a form,
// collect responses on chain, read them back rendered — with gnoweb as the
// only UI.
//
// # How it works
//
// The realm renders each form with p/jeronimoalbi/mdform. gnoweb turns that
// markdown into a real HTML form whose submit builds a /vm.m_call to Submit,
// mapping every input to the Submit parameter of the same name. A respondent
// fills the form in a browser, signs with their wallet, and the answers land
// in realm state. No frontend, no backend, no indexer.
//
// # Slugs
//
// A form's ID is a slug chosen at creation — lowercase letters, digits and
// single hyphens, 3 to 48 characters, unique per realm. It is the URL
// segment: /r/<ns>/forms:valoper-questionnaire. Response IDs are sequential.
//
// # Field encoding
//
// Create takes four parallel, pipe-separated strings so it stays usable from
// gnokey and gnoweb without structured arguments:
//
//	labels:   "Name|Why gno.land?|Server type"
//	kinds:    "text|textarea|select"
//	required: "1|1|0"
//	options:  "||cloud,on-prem,data-center"
//
// Kinds are text, textarea, number and select. Options are comma-separated
// and only read for select fields. A form has at most MaxFields (8) fields;
// Submit accordingly takes eight answer slots, of which the form's field
// count are read and the rest must be empty. gnoweb passes "" for any
// parameter the form does not render an input for.
//
// # Who pays
//
// Respondents pay the storage deposit for their own answers, which is the
// spam resistance. Withdraw deletes a response and the chain refunds the
// deposit to the caller — which is why only the author may withdraw: a
// deletion by the owner would refund the owner with the respondent's coins.
//
// # What is public
//
// Everything. Answers, who gave them, and when are all readable by anyone
// from realm state and from the transactions themselves. This realm is for
// information that can be public. Sealed responses would need encryption
// on the respondent's side before the transaction exists, which gnoweb
// cannot do on a realm's behalf; that is a deliberate non-goal of v1.
//
// # Routes
//
//	/r/<ns>/forms                     index
//	/r/<ns>/forms:<id>                a form, fillable
//	/r/<ns>/forms:<id>/responses      responses, paginated
//	/r/<ns>/forms:<id>/responses.csv  responses as CSV in a code block
package forms
