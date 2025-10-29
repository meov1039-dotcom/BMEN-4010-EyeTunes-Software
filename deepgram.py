#import the libraries requests and time
import requests
import time

#add our personal API key for Deepgram
DEEPGRAM_API_KEY = "REMOVE FOR SECURITY"

#add a sample audio file
AUDIO_FILE = "test2.mp3"

#locate the URL for the Deepgram API
url = "https://api.deepgram.com/v1/listen"

#setup Deepgram API with our API key
headers = {
    "Authorization": f"Token {DEEPGRAM_API_KEY}"
}

#choose settings to add punctuation and set language to english
options = {
    "punctuate": "true",
    "language": "en"
}

#begin tracking transcription time
start_time = time.time()

#perform transcription
with open(AUDIO_FILE, "rb") as audio:
    response = requests.post(
        url,
        headers=headers,
        params=options,
        files={"audio": audio}
    )

end_time = time.time()
elapsed_time = time.time()

result = response.json()

#print transcript result (added debugging print statements to help with troubleshooting)
if "results" in result:
    transcript = result["results"]["channels"][0]["alternatives"][0]["transcript"]
    print("Transcript:")
    print(transcript)
    print(f"\n Transcription took {elapsed_time:.2f} seconds.")
else:
    print("Transcription failed. Response:")
    print(result)

