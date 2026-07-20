package counter

// Variable d'état (doit commencer par une majuscule pour être exportée)
var Counter int

// Initialisation
func init() {
    Counter = 0
}

// Récupérer la valeur actuelle
func Get() int {
    return Counter
}

// Incrémenter le compteur
func Incr() int {
    Counter++
    return Counter
}

// Décrémenter le compteur
func Decr() int {
    Counter--
    return Counter
}

// Réinitialiser
func Reset() {
    Counter = 0
}
