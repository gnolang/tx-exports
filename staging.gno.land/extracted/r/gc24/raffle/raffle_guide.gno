package raffle

import (
	"std"
	"strings"
)

var (
	raffleRealmPath = std.CurrentRealm().PkgPath() // will give you portal loop path
)

func RenderGuide() string {

	text := `# Entering the raffle

Welcome, gopher!

You've decided to enter the gno.land raffle to get a chance to win a valuable prize.
We congratulate you on your curiosity and courage!

You will need your personal computer and a bit of time to enter the raffle. Find 
a quiet corner and read the rest of this README file.
Also, make sure you've gotten your unique raffle entry code at the gno.land booth -
you will not be able to proceed without it.

## Why enter the raffle?

Apart from getting a chance to win awesome prizes, you will be able to learn
a couple of basic concepts on how to use Gno, as well as some supporting Gno tools -
the [Gno Playground](https://play.gno.land), which will help you deploy your own 
Gno code, and [Connect](https://gno.studio/connect), which will
allow you to easily call smart contracts (called "!realms"! in Gno) that live on
the gno.land blockchain.

We've created this raffle to reward gophers that are curious and eager to learn
about new tech- if you can relate, you're in the right place!

After completing a series of steps, you'll have a chance at winning one of
the raffle prizes - we're giving away two Keychron K2 Pro mechanical keyboards.

## How do I enter?

To enter the raffle, you will need to go into dev mode. You need to take a look 
at some Gno code, learn how to interact with the gno.land blockchain, and submit
your raffle entry to the Raffle realm - which you are viewing right now!
This text, as well as the "Stats" at the top of the page are actual live state of
the Raffle realm.

We want you to try to figure things out on your own; you should prove your curiosity
and ability to learn about new technology in a short period of time. If, however, 
you do run into issues - the engineers at the gno.land booth will be able to help 
you.

## Let's get started!

Entering the raffle involves two main parts:
1. Registering your raffle code, which you got from the gno.land booth
2. Registering your GitHub username

Both of these involve interacting with the Raffle realm. 
You're currently reading the rendered state of the realm;
and you can view its source code by clicking on the [[source]](https://REALMPATH/)
button on the top right of the page.

## 1. Making a gno.land keypair

A keypair is what allows you to interact with the gno.land blockchain. For this, you
can use the Adena wallet- it will generate a keypair for you. You will then be able
use this keypair to deploy your own Gno code to the blockchain and call functions on 
existing Gno code, such as this Raffle realm.

Visit the official [Adena website](https://adena.app) to install it. 

After installing the Adena wallet as an extension, a page will pop up.
To create a keypair, follow the steps below.  

First, select "Advanced options" > "Create new wallet". Then, complete a 
questionnaire. You're free to look up the concepts Adena is telling you about
during this process (such as "seed phrase").

After saving your seed phrase and entering a password to protect your keypair,
you should be able to see your account generated in the Adena extension.
What you need to proceed to the next step is the address of your account,
which is further derived from your keypair. You'll be able to find it at
the top of the Adena extension.

You are ready to move onto the next step!

## 2. Get GNOTs

What are "!GNOTs"!? - you might ask. 

Blockchains are transactional systems; every interaction with a blockchain is 
done via a transactional message - ensuring the state of the network is consistent at each point 
in time. On top of this, to prevent DDoS attacks, all blockchains implement 
a gas system; for every state change on the network (a transaction), a user must 
pay with the network's native currency.

In the case of gno.land, this is "!GNOT"!. To get some testnet "!GNOT"!, 
visit the [gno.land Faucet Hub](https://faucet.gno.land). 

Select "Gno Portal Loop", enter your Adena address (copy it from the top of the Adena
wallet! it starts with "!g1..."!), select "!10 GNOT"!, complete the captcha, and click
"Request drip". Soon, you should see 10 "!GNOT"! available in your Adena wallet. You'll
need these later.

## 3. Inspecting Gno source code

Each Gno realm lives on a specific package path. In the case of the Raffle realm,
this path is "!REALMPATH"!. All files that comprise the realm can be found by
clicking the [source] button on the top right corner. There, you will find a "!raffle.gno"!
file. This is the main code of the Raffle realm.

To enter the raffle, you must inspect the Gno code found in this file.

Go do it now! You should be able to figure out the next step yourself.

...

...

...

Welcome back!

By reading some code, you found out that you need to write and deploy some Gno code.

## 4. Writing Gno code in the Gno Playground

The next step to entering the raffle is writing a bit of Gno code and deploying
it to the gno.land blockchain. 

Before diving into the code, let's learn about how the gno.land blockchain stores 
data.

All code uploaded to gno.land lives on a specific path, like in a file system.
For example, you were able to find the Raffle realm on "!REALMPATH"!.
This path is a crucial piece of any realm- apart from being able to 
call all exported functions in the Gno code by specifying its path (a next step!), the path can 
also be used to import the code into your own application, providing reusability
of code and interaction between applications that live on the chain.

The path of the Raffle realm can also be found in the "!gno.mod"! file,
which you can also find on the [source] page.

If you have read through the "!raffle.gno"! file, you may have noticed that "!RegisterCode()"! 
can only be called _via other code_. Try to use the Gno Playground to write your own Gno
app that will import the Raffle realm.

Figure out where to use the "!RegisterCode()"! function, and make sure to add
your (case sensitive!!) raffle code as a string argument when calling it.

## 5. Deploying Gno code

A crucial step in entering the raffle is deploying your Gno code to the blockchain.
Doing this will complete the first part of the raffle entry - registering your 
raffle code.

Luckily, [Gno Playground](https://play.gno.land) provides an easy way to deploy code- after writing your
desired code, you can click on "Deploy". This will:
- Allow you to connect your Adena wallet to the Playground
- On the top right corner of the Playground, choose the network you want to deploy
your code to - you should select "Portal Loop"
- Pick a deployment path for your realm - choose the "!r/"! prefix, enter in your
namespace (it can be your username), and match your Gno package name to the last
part of the path. A suggested deployment path could be ""!gno.land/r/gc24/myusername/raffle"!",
while the package name would need to be ""!raffle"!"

Clicking on "Deploy" will prompt an Adena window that will ask you to sign
the transaction which will upload your code to the chain. The "!init()"!
function will get executed upon deployment.

Congratulations! You've made it through the hard part.

With this, you've connected your address with the raffle code you've received.

You should be able to see your raffle code show up in the Stats section at the top 
of the page. Don't worry about everyone being able to see your code; codes are usable
only once.

## 6. Registering your GitHub username

Final step! You need to register your GitHub username to complete your raffle entry.
Look for a function in the "!raffle.gno"! file which will allow you to do so, and figure
out a way to do it. 

If you've succeeded, you'll see your username show up in the "Stats" section at the top.

!!! Make sure to register your real GitHub username; if you are chosen as a winner,
you will have to prove you have access to the GitHub account !!!

## Conclusion

Congratulations on entering the Raffle! Sit back, relax, and wait for the winner
announcement time at the gno.land booth.`

	text = strings.Replace(text, "REALMPATH", raffleRealmPath, -1)
	text = strings.Replace(text, "\"!", "`", -1) // go/gno complains about ` inside ``

	return text
}
