package safe

// words are blocked words and phrases, normalized (lowercase ASCII, single
// spaces). Sources: LDNOOBW "List of Dirty, Naughty, Obscene and Otherwise Bad
// Words" (en, fr, es, de, it, pt, nl; CC BY 4.0), the strongest keywords of the
// gno.land antispam proposal (gnolang/gno#5178), slurs and insults added by
// hand, and the 2026 content audit: threats, self-harm, hate codes, scam lures,
// misspellings and insults in tr, pl, ru, ar, hi, ro, sv, id, tl, ja, zh.
// Common words of another language were left out (con, sega, fava, xx…), and
// so were identity words (homosexual) and common words that only look bad
// (yourself, bitte, peter, tard).
const words = `
aardappels afgieten
aborto
account locked
account suspended
achter het raam zitten
acrotomophilia
act now
actfast
add me on whatsapp
adderall
adolf did nothing wrong
afberen
aflebberen
afrossen
afrukken
aftrekken
afwerkplaats
afzeiken
afzuigen
airdrop
airdrop claim
airdrop live
airdrops
al qaeda
alabama hot pocket
alaskan pipeline
allupato
alqaeda
amcik
amina koyayim
amina koyim
aminakoyim
amk
ammazzati
ammucchiata
amphetamine
anabolic
anal
anale
analritter
anilingus
anjing lo
anus
apeshit
approvalscam
aranha
ariano
arnaque
arrapato
arrombada
arrombado
arrusa
arruso
arsch
arschficker
arschlecker
arschloch
arse
arsehole
aryan brotherhood
aryan nation
aryan nations
aryan pride
asbak
asesinato
asesino
asno
ass
assassinat
assassinato
assatanato
asshat
asshole
assmunch
asswipe
atomwaffen
attarde
auslander raus
auto erotic
autoerotic
babaca
babeland
baby batter
baby juice
bagascia
bagassa
bagger schijten
bagnarsi
baise moi
bajingan
balalao
baldracca
ball gag
ball gravy
ball kicking
ball licking
ball sack
ball sucking
bamboula
bander
bangbros
bangbus
bangsat
bareback
barely legal
barenaked
bastard
bastardo
bastinado
batar
batard
batarde
battere
battona
bbw
bdsm
beaner
beaners
beastiality
beaver cleaver
beaver lips
bedonderen
befborstel
beffen
beheading
behenchod
belastigung
belazeren
belino
bellend
belong in kitchen
belong in the kitchen
benchod
bencong
besodemieterd zijn
besodemieteren
bestiality
betrug
beyotch
bhadwa
bhadwe
bhenchod
bhosadike
bhosda
bhosdi
bhosdike
biao zi
biaozi
biatch
bicha
bicot
bicots
big breasts
big knockers
big tits
bigornette
bimbo
bimbos
bin laden
binance support
binary options
biotch
birdlock
biscate
bit ly
bitch
bitches
black cock
blackmarket
blanchiment
blanqueo
blatte
bloblos
blonde action
blonde on blonde action
blood and honor
blood and honour
bloodbath
blow job
blow your load
blowjob
blue waffle
blumpkin
blya
blyad
blyat
bocchinara
bocchino
boceta
boemelen
boerelul
boerenpummel
bofilo
boiata
bokkelul
bollera
bollocks
bollox
bomb threat
bondage
boner
bonze
boob
boobs
bookie
booty call
bordel
bordello
bosta
botergeil
botnet
bougnoul
bougnoule
bourre
bourree
boylover
brackmard
branlage
branler
branlette
branleur
branleuse
braquage
bratze
braulio de borracha
brengsek
brinca
bring dich um
broekhoesten
brothel
brouter le cresson
brown showers
brugpieper
brunette action
bucaiolo
buceta
budiulo
buffelen
buiten de pot piesen
bukkake
bulangiu
bulldyke
bullet vibe
bullshit
bumbum
bumsen
bung hole
bunghole
burat
busone
busty
butt
buttcheeks
butthole
buy coke
buy drugs
buy followers
buy weed
cabrao
cabron
cabrona
cabrones
cacca
cacete
caciocappella
cadavere
cagar
cagare
cagata
cagna
camel jockey
camel toe
camgirl
camisinha
camslut
camwhore
cannibalism
cannibalisme
cao ni ma
caonima
caralho
carpet muncher
carpetmuncher
casci
cash app
cashapp
cashout
cashprize
cassos
cazzata
cazzimma
cazzo
cazzone
cesso
chantage
chantagem
chantaje
charmouta
chatte
chaturbate
checca
check my bio
check my profile
chernozhopy
chiappa
chiasse
chiavare
chiavata
chier
childlover
childporn
chinaman
chinetoque
ching chong
chinga
chingada
chingar
chingate
chingchong
chink
chinko
chinks
chinky
chinpo
chintok
chiottes
chmo
chochota
chocolate rosebuds
chodu
chootiya
christ killer
chuj
chuja
chupada
chupame
chupapollas
chupar
chupeton
chutia
chutiya
chutmarike
cialis
cinayet
ciospo
ciota
cipa
circlejerk
ciucciami il cazzo
claim airdrop
claim bonus
claim fast
claim free
claim gnot
claim here
claim nft
claim now
claim prize
claim reward
claim tokens
claim your
claim your airdrop
claim your reward
claim yours
cleveland steamer
click here
click the link
clickbait
clit
clito
clitoris
clover clamps
clusterfuck
cnm
cocaina
cocaine
cock
cocks
cocksucker
cocksuckers
coglione
coglioni
coinbase support
coito
colhoes
combat ib
comemierda
commit suicide
complete kyc
cona
conar
conasse
concha de tu madre
conchatumadre
connar
connard
connasse
conne
connect wallet
connect your wallet
cono
contact admin
contact me on whatsapp
coon
coons
coprofagia
coprolagnia
coprophilia
cornhole
corno
cornuto
couille
couilles
counterfeit
cozza
cp for sale
crackhead
cramouille
creampie
creve sale
crypto giveaway
crypto signals
cryptoscam
crystal meth
ctm
cuck
cuckold
cul
culattina
culattone
culero
culiado
culiao
culo
cum
cumdump
cumming
cumshot
cumshots
cumslut
cunnilingus
cunt
cunts
curry muncher
customer support team
cvnt
cyberbully
cyka
da s kloten van de bok
daesh
dago
dagos
daily profit
dapp support
dar o rabo
darkie
darknet
darkweb
darky
date rape
daterape
de hoer spelen
de pijp uitgaan
deaththreat
decapitacion
decapitation
deconne
deconner
deep throat
deepthroat
dendrophilia
desnudo
detonator
di merda
dick
dickhead
dickheads
dickpic
dicks
die bitch
die in a fire
dildo
dingleberries
dingleberry
dio cane
diocane
dipshit
dirty jew
dirty pillows
dirty sanchez
disembowel
dismember
ditalino
dm for promo
dm me for
dm me on telegram
dodel
dog style
doggie style
doggiestyle
doggy style
doggystyle
dolandirici
dolbaeb
dolboeb
dolcett
dombo
domination
dominatrix
dommes
donkey punch
dot land
dothead
double dong
double penetration
double your
double your crypto
double your gnot
douchebag
dox
doxed
doxx
doxxed
doxxing
dp action
draaikont
drainer
drecksack
drecksau
driehoog achter wonen
drink bleach
drogas
drogenhandel
drooggeiler
droogkloot
drug dealer
drugdealer
dry hump
dum raio
dumbass
dvda
dyke
dykes
dziwka
earn daily
earn gnot
eat my ass
eb tvoyu mat
ebat
ecchi
ecstasy
een beurt geven
een halve man en een paardekop
een nummertje maken
een wip maken
eff you
eikel
ejaculation
elon giveaway
elon musk giveaway
emmerdant
emmerder
emmerdeur
emmerdeuse
encule
enculee
enculer
enculeur
enculeurs
enfoire
enfoiree
engerd
enlargement
entfuehrung
enthauptung
entot
erotic
erotism
erpressung
escroquerie
esperma
esporra
estafa
estafador
estorsione
estuprador
estupro
etron
eunuch
exitscam
extorsao
extorsion
f d p
f you
faelschung
fag
faggot
faggots
fags
fakeairdrop
fakegiveaway
fakeid
fakemint
fakewallet
fap
fapping
fcuk
fdp
fecal
felch
fellatio
feltch
female squirting
femdom
femminuccia
fentanyl
fica
fick
ficken
ficker
fickt
fiesta de salchichas
figa
figging
figlio
figlio di buona donna
figlio di puttana
figone
filho
filho da puta
fille de pute
fils de pute
fingerbang
fingering
finocchio
fiotte
fisse
fisting
fitta
fittan
fitte
fittetryne
fk u
fk you
fking
fkn
flamoes
flikken
flikker
flittchen
foda
foda se
fodase
foder
fodido
follador
follar
folter
foot fetish
footjob
forex
forex signals
fottere
fottersi
fotze
fotzen
fourteen words
foutre
fracicone
frango assado
fratze
fraude
free airdrop
free airdrops
free btc
free crypto
free eth
free giveaway
free gnot
free mint
free nft
free tokens
fregna
froci
frocio
froscio
frotting
ftg
fuck
fuck buttons
fucker
fuckface
fuckin
fucking
fucktards
fudge packer
fudgepacker
fuk
fukk
fukka
funds recovery
fuq
futanari
futu ti
futui
fuxk
fvck
g spot
gaand
gadverdamme
gahba
galbak
gandon
gandu
gang bang
gangbang
gas the jews
gas them
gavat
gay sex
gedoogzone
geilneef
geldwaesche
gem alert
genitals
gesodemieter
getrichquick
ghb
giant cock
gilf
gilipichis
gilipollas
girl on top
girllover
girls gone wild
girls i cup
giveaway
giveaway winner
giveaways
gnot giveaway
go back to africa
go back to your country
go back where you came from
go die
goatcx
goatse
goblok
god damn
godverdomme
going to kill you
gokkun
golden shower
goldone
golliwog
gonna kill you
goo girl
goodpoop
gook
gooks
goregasm
gory
gotveren
gou ri de
gouine
gouride
gozar
graftak
grande folle
gratenkut
greaseball
great replacement
grelho
greppeldel
grognasse
grogniasse
grope
group sex
gtfo
guaranteed
guaranteed income
guaranteed profit
guaranteed returns
guardone
gueule
gunshop
guro
gyppo
hacer una paja
haciendo el amor
hacked wallet
hackfresse
hail victory
halt die fresse
hameconnage
hand job
handjob
hang dich auf
hang urself
hang yourself
harami
haramzada
haramzadi
harcelement
hard core
hardon
hatecrime
heeb
heil
helpdesk
hentai
her address
heroin
heroina
hh bb
hidden gem crypto
hija de puta
hijaputa
hijo de puta
hijoputa
hijueputa
hindot
his address
hitla
hitler
hitlr
hitman
hoempert
hoer
hoerenbuurt
hoerenloper
hoerig
holocaust hoax
holocaust was fake
holohoax
homem gay
homoerotic
homoerotico
honeypot
honkey
honky
hooker
hope you die
horeunge
horny
horseshit
horunge
hot carl
hot chick
how to kill
how to murder
hpta
hufter
huge fat
huisdealer
huj
humping
hundan
hure
hurensohn
hurensohne
hussyfan
hymie
i will kill you
ia bb
ia words
iabb
ibn el kalb
ibn kalb
ibne
identitytheft
idi nahui
idiota
ill kill you
imbecil
imbecille
inbaita
inbox me
incazzarsi
incest
inceste
incesto
incoglionirsi
infanticide
infierno
ingoio
injun
ins gas
intercourse
investment opportunity
investment plan
iooox
ioox
iox returns
ische
isis forever
jack off
jackass
jacking off
jail bait
jailbait
jancok
jancuk
jap
japs
javla
je te baise
je vais te buter
je vais te tuer
jebac
jebana
jebany
jerk off
jerking off
jewboy
jhaatu
jhant
jigaboo
jiggaboo
jiggerboo
jihadi
jihadist
jilipollas
jizz
joder
jodete
jodido
join my telegram
joto
jouir
juden raus
judensau
juggs
jungle bunny
kackbratze
kacke
kacken
kackwurst
kaffir
kaffirs
kahba
kahpe
kaltak
kamina
kampflesbe
kampret
kanacke
kanake
kanen
kanjar
kankerhoer
kankerjood
kankerlijer
kankermongool
kantot
kantutan
kapullo
katsap
keparat
ketamine
kettingzeug
keylogger
khokhol
khuy
khuynya
kichigai
kiddie porn
kiddy porn
kike
kikes
kill all blacks
kill all gays
kill all jews
kill all muslims
kill the jews
kill ur self
kill urself
kill yaself
kill yoself
kill your self
kill yourself
kill yourselves
kimak
kimme
kinbaku
kinderficker
kinderporno
kinkster
kkk
klaarkomen
klere
klerebeer
klojo
klooien
klootjesvolk
klootoog
klootzak
kloten
kneppe
knobbing
knobhead
knockoff
know where you live
knull
knulla
knulle
kokain
konnard
kont
kontneuken
kontol
kos omak
kos ommak
kosomak
kossomak
krentekakker
krijg de kanker
ku klux
ku klux klan
kuk
kukhue
kukluxklan
kuksugare
kunt
kupal
kurwa
kurwy
kus emak
kusoyaro
kut
kutas
kuttelikkertje
kutwijf
kwakkie
kyc
kyke
kys
la putain de ta mere
labagiu
ladyboy
lameculos
lastchance
launder
lavagem
lavda
leather restraint
leather straight jacket
leccaculo
lecchino
ledger support
lemon party
les arabes dehors
les juifs dehors
les noirs dehors
lesbo
lezzer
lezzie
liefdesgrot
limited offer
link in bio
link in my bio
livejasmin
livesex
ll kill you
lofare
loffa
loffare
lolicon
long live isis
lonte
lost crypto
louti
lovemaking
luder
lul
lul de behanger
lulhannes
lummel
maa ki chut
maak je dood
maciza
macizorra
maconha
madarchod
madarchoda
maderchod
mafketel
makaak
make money fast
male squirting
malparido
malpt
malware
mamada
mamaguevo
mamahuevo
mannaggia
manyak
manyouk
marica
maricon
maricona
mariconazo
maricones
masacre
massacre
massaker
masturbate
masturbating
masturbation
matate
matennaaier
matje
mdma
mein kampf
memek
menage a trois
merd
merda
merdata
merde
merdeuse
merdeux
merdoso
message me for
metamask
meth
methamphetamine
methhead
meuf
meurtre
mierda
mietje
mignotta
milf
minchia
minchione
minor attracted
mint live
mint now
missgeburt
missionary position
mnemonic
mnemonic phrase
mof
molest
molester
moneylaunder
mongol
mongolen
mongolien
mongolo
mongoloid
mongoloide
monkey
montare
moonshot
mopse
mord
morgenlatte
motherfucker
mound of venus
mr hands
mudak
muerete
muff diver
muffdiving
mufti
muie
muist
muschi
mussa
mutilation
mutiler
muzzie
muzzies
naakt
nackt
nahui
nahuy
nakhuy
nambla
narcotics
narcotraficante
nave scuola
nawashi
nazi
nazis
neck urself
neck yourself
necrophilia
neger
negrata
negre
negresse
negri
negro
neonazi
nerchia
neuken
neukstier
next gem
ngentot
ni ma bi
niakoue
nig nog
nigga
niggas
nigger
niggers
nigguh
nigka
nignog
nik mok
nikker
niktamer
nimabi
nimphomania
nippel
nipple
nipples
niq ta mer
niqqa
niqqer
nique
nique ta mer
nique ta mere
nique ta race
niquer
nomap
nsdap
nsfw
nsfw images
ntm
nude
nudes
nudity
nutte
nutten
nympho
nymphomania
octopussy
oetlul
official support
omanko
omicidio
omorashi
onanieren
one cup two girls
one guy one jar
only fans
onlyfans
op z n hondjes
op z n sodemieter geven
opgeilen
opioid
opium
opkankeren
oprotten
opsodemieteren
opzouten
orgasm
orgasme
orgasmus
orgy
orina
orospu
orospu cocugu
orospucocugu
osama hero
otario
ou tu habites
ouwe rukker
ouwehoer
ouwehoeren
oven dodger
ovendodger
oxycodone
oxycontin
paardelul
padulo
paedo
paedophile
paedophiles
paedophilia
paedos
pajeet
paki
pakis
pakshet
pakyu
palen
palle
palloso
palucher
paneleiro
panties
panty
passar um cheque
passive income
patacca
patonza
patriot front
pd
pecorina
pedale
pede
pedes
pedik
pedo
pedobear
pedofila
pedofilia
pedofilo
pedofilos
pedophile
pedophilia
pedos
pegging
peidar
pekpek
pelacur
pend toi
pendeja
pendejo
pends toi
penis
penoze
pepek
percocet
pervertido
petasse
pezevenk
pezon
phantom wallet
phishing
phone sex
phuck
phuddi
picaninny
picio
pickaninny
pidaras
pidor
pidoras
piece of shit
pierdole
pierdolic
piesen
pija
pijpbekkieg
pijpen
pikey
pikhoved
pikk
pillow biter
pimmel
pimp
pimpern
pincare
pinche
pinkeln
pinnolone
pippone
pirla
piroca
pisciare
piscio
pisello
piss pig
pissen
pisser
pissing
pisspig
pistolotto
pizda
pizda matii
pizdec
pizdets
playboy
pleasure chest
pleur op
pleurislaaier
poep
poepen
pole smoker
pomiciare
pompino
ponyplay
ponzi
poo in loo
poof
poon
poontang
poop chute
poopchute
popel
poponar
poppen
porca
porca madonna
porca miseria
porca puttana
porch monkey
porco
porco due
porco zio
porcodio
porn
pornhub
porno
pornografi
pornografia
pornografie
pornographie
pornography
porra
portiekslet
potta
potverdorie
pouffiasse
poufiasse
pousse crotte
pqp
pre sale
presale
prince albert piercing
private key
privatekey
promo code
prostituta
prostitute
proud boys
proxeneta
proxenete
pthc
ptn
pubes
publiciteitsgeil
puki
pukimak
pump and dump
pumpanddump
punany
punyeta
puppami
pussi
pussies
pussy
puta
puta que pariu
puta que te pariu
putain
putang ina
putangina
putas
pute
putes
putita
puto
puttana
puzzy
pvtain
pyramid scheme
qahba
queaf
queca
queef
quim
raaskallen
race war
racewar
racista
raghead
raging boner
rahowa
ramera
ramoner
ransomware
rape
rape you
raped
rapimento
raping
rapist
rapists
rauschgift
raygold
recchione
recover funds
recover wallet
recover your wallet
recovery phrase
recovery service
rectum
redskin
reet
reet trappen voor zijn
reetridder
ref link
referral code
reggin
remsporen
rentre dans ton pays
restore wallet
restore your wallet
retard
retardado
retarded
retards
retourne dans ton pays
reudig
reutelen
reverse cowgirl
ri ni ma
ricchione
riciclaggio
rimjob
rimming
rincoglionire
rinima
rizzarsi
rohypnol
rompiballe
rompipalle
roofie
roofies
rorikon
rosy palm
rosy palm and her s sisters
rothoer
rotjood
rotzak
roubo
rovhul
rovhull
ruffiano
rug pull
rugpull
rukhond
rukken
rusty trombone
sac a foutre
sac a merde
sacanagem
sadico
sadism
salaud
sale arabe
sale juif
sale noir
sale race
salop
salopard
salope
salopes
sandnigger
sanglant
santorum
sao bi
saobi
sapatao
saujude
sbattere
sbattersi
sborra
sborrata
sborrone
sbrodolata
scam
scamcall
scammer
scammers
scamming
scams
schabracke
schatje
schei e
scheise
scheiss
scheiss auslander
scheissdreck
scheisse
scheisser
scheisskerl
schiesser
schijt
schijten
schlampe
schlong
schnackeln
schoft
school shooting
schuinsmarcheerder
schwanzlutscher
schwuchtel
scissoring
scopare
scopata
scorreggiare
se mata
secret phrase
secret recovery phrase
secuestro
seed phrase
seed words
seedphishing
seedphrase
segaiolo
seig
seigheil
selfharm
semen
send and receive
send gnot
send gnot get
send nudes
sendmoney
sequestrador
sequestro
serefsiz
sex
sexcam
sexe
sexo
sexo oral
sextape
sexting
sexually
sha bi
shabi
sharmoota
sharmouta
sharmuta
shaved beaver
shaved pussy
sheeit
shemale
shibari
shiet
shit
shitblimp
shite
shitface
shithead
shits
shitting
shitty
shluha
shlyukha
shoot up the school
shoot yourself
shota
shotacon
shotakon
shrimping
shrooms
shyt
sieg heil
siegheil
sikerim
sikeyim
sikik
siktir
siktir git
silencer
sit on my face
six million wasnt
skeet
skurwiel
skurwysyn
slanteye
slempen
slet
sletterig
slik mijn zaad
slinguare
slinguata
slit your throat
slit your wrists
slopehead
slut
sluts
slutty
smandrappata
smut
snatch
sniperbot
snol
snowballing
snuff
soccia
socmel
sodomite
sodomize
sodomy
soplagaitas
soplapollas
sorca
spacciatore
spagnola
spast
spastic
spaz
speedball
spic
spics
spierdalaj
splooge
splooge moose
spompinare
spooge
sportsbet
spread legs
spuiten
spunk
spyware
squaw
stab you
stalking
standje
steroid
stfu
sticchio
stoephoer
stootje
strap on
strapon
strappado
strip club
stripper
stront
stronza
stronzata
stronzi
stronzo
stupratore
stupro
style doggy
subnormal
succhiami
succhione
suce
suceur
suceuse
sudaca
sufferd
sugi pula
suicidate
suicidati
suicide girls
suicide is the answer
suicide toi
suka blyat
sultry women
sundal
support team
supremacist
svartskalle
sveltina
sverginare
swastika
swatted
swatting
sweeper
swinger
sync wallet
sync your wallet
ta ma de
ta mere
tafiole
tamade
tamere
tanche
tang ina
tangina
tantouze
tapette
tapijtnek
tarantado
tarlouze
tarzanello
te buter
te matar
te tuer
te voy a matar
tea bagging
teef
teezak
telegram channel
telegram group
temeier
teri maa ki
tering
teringlijer
terrone
testa di cazzo
tetas grandes
tette
teub
teuch
thot
thots
threesome
throating
thumbzilla
ti ammazzo
tia buena
tight white
titjob
tits
tittchen
titten
titties
titty
tnc
toeter
tolol
tongzoeng
topless
torneira
tortillera
tortura
tosser
tote dich
towelhead
trading bot
trafficking
traficante
trafiquant
trannies
tranny
transar
traveco
travelo
travesti
tribadism
tringler
triootjeg
trique
trisomique
troia
trombare
troncher
trottoir prostituee
trottoirteef
trou du cul
truffa
trust wallet
tub girl
tubgirl
tue toi
tunte
turlute
tushy
twat
twats
twink
twinkie
two girls one cup
tyfus
tyfuslijer
uccidi te
uebok
ulol
unalive
underage nudes
undressing
unlock wallet
unlock your wallet
upskirt
urethra play
urophilia
usdc giveaway
usdt
use my code
uyusturucu
va crever
va mourir
vacca
vadia
vaffanculo
vagabunda
vagina
vai se matar
vai te foder
vai tomar no cu
validate wallet
validate your wallet
vangare
veado
venmo
venus mound
verga
vergallen
vergewaltigung
verify kyc
verify your wallet
verkloten
vermoord je
verneuken
verpiss dich
vete a la mierda
viado
viagra
vibrador
vibrator
viespeuk
vingeren
violacion
violador
violet wand
violeur
visit my profile
vleesroos
vogeln
vollpfosten
voor jan lul
voor jan met de korte achternaam
vorarephilia
votze
vou te matar
voyeur
voyeurweb
voyuer
vsf
vtnc
vulva
wallet recovery
wallet support
wallet support team
wallet sync
wallet validation
wang ba dan
wangbadan
wank
wanker
wankers
wanking
wanna bang
watje
welzijnsmafia
western union
wet dream
wetback
whatsapp me
white power
whitelist open
whitelist spot
whore
wichse
wichsen
wichser
wigga
wigger
wijf
will not replace us
wiretransfer
wop
wops
workfromhome
worldsex
wrapping men
wrinkled starfish
wuftje
wypierdalaj
xanax
xiao riben
xioo
xiooo
xochota
xvideos
xxx
yaoi
yarak
yariman
yarrak
yebat
yellow showers
yid
yids
yiffy
yob tvoyu mat
you should die
youpin
youpine
zaadje
zajebac
zakkenwasser
zalupa
zamel
zebbi
zeiken
zeiker
zhid
zhina
zhyd
zigeuner
zigounette
zinne
zio cantante
zipperhead
zob
zoccola
zogbot
zoophile
zoophilia
zorra
zuigen
zuiplap
zwartjoekel
`
