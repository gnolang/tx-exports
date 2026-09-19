# Datastore Package

Package provides support to store multiple collections of records.

It supports the definition of multiple storages, where each one is a collection
of records. Records can have any number of user defined fields which are added
dynamically when values are set on a record. These fields can also be renamed
or removed.

Storages have support for simple schemas that allow users to pre-define fields
which can optionally have a default value also defined. Default values are
assigned to new records on creation.

User defined schemas can optionally be strict, which means that records from a
storage using the schema can only assign values to the pre-defined set of fields.
In which case, assigning a value to an unknown field results in an error.

Package also supports the definition of custom record indexes. Indexes are used
by storages to search and iterate records. The default index is the ID index but
custom single and multi value indexes can be defined.

> [!WARNING]
> Using this package to store your realm data must be carefully considered.
> The fact that record fields are not strictly typed and can be renamed or removed
> could lead to issues if not careful when coding your realm(s). So it's recommended
> that you consider other alternatives first, like alternative patterns or solutions
> provided by the blockchain to deal with data, types and data migration for example.

Repository can be found at [jeronimoalbi/gnome](https://github.com/jeronimoalbi/gnome),
as part of `jeronimoalbi`'s Gno smart contracts monorepo.

## Usage

[embedmd]:# (filetests/readme_filetest.gno go)
```go
package main

import "gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/datastore"

func main() {
	db := datastore.NewDatastore()

	// Define a unique case insensitive index for user emails
	emailIdx := datastore.NewIndex("email", func(r datastore.Record) string {
		return r.MustGet("email").(string)
	}).Unique().CaseInsensitive()

	// Create a new storage for user records
	users := db.CreateStorage("users", datastore.WithIndex(emailIdx))

	// Add a user with a single "email" field
	user := users.NewRecord()
	user.Set("email", "foo@bar.org")

	// Save to assign the user ID and update indexes
	user.Save()

	// Find user by email using the custom index
	user, _ = users.Get(emailIdx.Name(), "FOO@bar.org")
	println("Found by email:", user.MustGet("email"))

	// Find user by ID
	user, _ = users.GetByID(user.ID())
	println("Found by ID:", user.ID())

	// Delete the user from the storage and update indexes
	users.Delete(user.ID())
	println("Users:", users.Size())
}

// Output:
// Found by email: foo@bar.org
// Found by ID: 1
// Users: 0
```

### Querying

[embedmd]:# (filetests/readme_query_filetest.gno go)
```go
package main

import "gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/datastore"

func main() {
	db := datastore.NewDatastore()

	// Define a multi value index to search posts by tag
	tagsIdx := datastore.NewMultiValueIndex("tags", func(r datastore.Record) []string {
		return r.MustGet("tags").([]string)
	})

	posts := db.CreateStorage("posts", datastore.WithIndex(tagsIdx))
	for _, title := range []string{"Post 1", "Post 2", "Post 3"} {
		post := posts.NewRecord()
		post.Set("title", title)
		post.Set("tags", []string{"gno", title})
		post.Save()
	}

	// Get two records starting from the second one
	recordset, err := posts.Query(datastore.WithOffset(1), datastore.WithSize(2))
	if err != nil {
		panic(err)
	}

	recordset.Iterate(func(r datastore.Record) bool {
		println("Post:", r.MustGet("title"))
		return false // Continue iterating
	})

	// Get all the records that have the "gno" tag using the custom index
	recordset = posts.MustQuery(datastore.UseIndex("tags", "gno"))
	println("Tagged posts:", recordset.Size())
}

// Output:
// Post: Post 2
// Post: Post 3
// Tagged posts: 3
```
