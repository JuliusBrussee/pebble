import PebbleCore

func runCommand(_ game: GameCore, _ raw: String) {
    executeGameCommand(game, raw, output: pushChat)
}
