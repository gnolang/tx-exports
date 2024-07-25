/* 

👋 Welcome to the "gnomymood" Realm!

In this example, we will explore how to change and display moods using a 
realm in Gno.land.

We'll do the following:

1. Start with a default mood.
2. Change the mood using a function.
3. Display the current mood using another function.

How it works together:

1. When we start, our mood is set to "neutral".
2. We can use the ChangeMyMood function to change our mood. 
   For example, if we say ChangeMyMood("happy"), our mood changes to "happy".
3. A Render function will then display the message "My Mood is happy".

Let's dive into the code!

*/

/*

Package Declaration:

This line declares the name of our realm. Think of it as naming a folder 
where all the related files for this mood-changing application will be stored. 
In this case, our folder is called "gnomymood".

*/

package gnomymood

/*

Starting Point:

Here, we're setting up a starting mood for our program. "var" means we're 
creating a variable (a storage box), and we're putting the word "neutral" 
inside this box. So, our mood starts as "neutral".

*/

var myMood = "neutral"

/*

ChangeMyMood Function:

- func: Short for "function," which is like a mini-program within our main program.
- ChangeMyMood: The name of this function. It’s like a command that changes our mood.
- newMood string: This part means the function takes in a new mood (like "happy" or 
  "ready for the weekend") as input.
- myMood = newMood: This line updates our mood to whatever new mood we give it.
- return "My mood has changed": This line sends back a message saying our mood has been 
  updated.

Imagine you have a remote control for your mood. You press a button to change your mood, 
and the remote shows a message confirming the change. That's what this function does!

*/

func ChangeMyMood(newMood string) string {

  // The function receives a new mood as input in the form of a string (text).
	// We use strings here because moods are best represented by text (e.g., "happy", "sad").

	myMood = newMood

  // The function returns a confirmation message for your mood change, which is also a string.

	return "My mood has changed"
}

/*

Render Function:

- func Render(path string) string: Another function, but this one is for displaying something.
- return "My Mood is " + myMood: This line combines the words "My Mood is " with whatever our 
  current mood is. It then shows this combined message.

The Render function is like a display screen that shows the current state of your realm 
in a readable format. So it returns the information in a format that's easy to read, often as 
simple text or Markdown.

In our example, it tells you what your current mood is.

Your mood board!

Whenever you want to check your mood, you look at this screen.

*/

func Render(path string) string {

  // The function combines the words "My Mood is " with whatever our current mood is 
  // and returns this combined message as a string.

	return "My Mood is " + myMood
}
