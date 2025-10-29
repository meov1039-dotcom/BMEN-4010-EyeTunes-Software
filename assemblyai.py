#import requests and time libraries
import requests
import time

#set AssemblyAI API as URL location
base_url = "https://api.assemblyai.com"

#set our personal API key
headers = {
    # Replace with your chosen API key, this is the "default" account api key
    "authorization": "REMOVED FOR SECURITY"
}

#set URL of the file to transcribe (.MP3 was loaded into URL through AssemblyAI website)
FILE_URL = "https://cdn.assemblyai.com/upload/79cb80e0-029b-4e04-ac5b-ef1d30247b94"

#additional parameters for the transcription
config = {
  "audio_url": FILE_URL,
  "speaker_labels":True,
  "format_text":True,
  "punctuate":True,
  "speech_model":"universal",
  "language_detection":True
}

#begin timing the transcription process
start_time = time.time()

#perform transcription using AssemblyAI transcription
url = base_url + "/v2/transcript"
response = requests.post(url, json=config, headers=headers)

transcript_id = response.json()['id']
polling_endpoint = base_url + "/v2/transcript/" + transcript_id

while True:
  transcription_result = requests.get(polling_endpoint, headers=headers).json()
  transcription_text = transcription_result['text']

#Print transcript
  if transcription_result['status'] == 'completed':
    print(f"Transcript Text:", transcription_text)
    break

#Print “error” if there was an error during the transcription
  elif transcription_result['status'] == 'error':
    raise RuntimeError(f"Transcription failed: {transcription_result['error']}")

  else:
    time.sleep(3)

#calculate and print the elapsed time of the transcription
end_time = time.time()
elapsed_time = end_time - start_time
print(f"\n Transcription took {elapsed_time:.2f} seconds.")
  
