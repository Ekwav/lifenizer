Lifenezier (Life orginizer) is a program that helps to organize and search ALL your information.

1. Import data from some source (google, whatsapp, PDF, Scanned Image, minecraft chats ...)
2. Search through all of it to find something you only remember partially (Conversation, a name, someones birthday)

## Motivation
Its very hard to remember stuff. I and wanted a way to save all of my data and make it searchable.

## Installation
### Development
1. Get docker
2. Get dotnet runtime
2. Clone this repo
4. `cd lifenizer`
3. `dotnet run`

### Usage
1. Install docker
2. execute with docker



## Terms
Stay consistant and use these words to avoid confusion
- `conversation` any kind of information exchange, can be single word to whole groupchat history. 
- `importer` gets external data into the system and feeds it to an `converter`
- `converter` is the system that takes some data and converts it to a `conversation`
- `searcher` is the system for indexing and searching `conversations`


## Start To Finish

Lets say you have some data, eg a letter, and you want to import it. How does it work?
1. You need an importer, eg. `Scan`. It will get your document into the system by scanning it and saving it to the filesystem.
2. You need an converter, eg. `ImageOcr`. This will take the scanned image and get the interesting content out of the data (create a [`conversation`](#terms)). In this case whatever is written on the letter.
3. You need a `searcher`, eg. `FileBased`. It takes care of saving and indexing the data in a way that it can be searched quickly.
4. The search engine can be queried for the text in the letter and will return the scanned image.

### Planed/available
#### Importers
* Scan 
* download 
* http (post)

#### Converter
* Speech2Text
* Ocr PDF
* Ocr Image
* E-Mails
* Chats
    * Discord
    * Whatsapp
    * Telegram
    * Skype
    * Signal
    * Steam
    * Minecraft
    * Facebook
* Twitter
* Youtube 
    * comments
    * text in video 
    * speach in video / subtitles
    * Description
* Websites (Browserhistory)
* Speech recognition
    * Cloud Providers
    * Locally via DeepSepeach


#### Searchers
* `LuenceSearch` 
* `ElasticSearch` 