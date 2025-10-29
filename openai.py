#import OpenAI SDK to use the functions within the library
import openai 
import time

#add our personal API_key
openai.api_key = "REMOVE FOR SECURITY"

#load in audio file in .MP3 format
audio_file_path = "test2.mp3"
#begin timing to track how long it takes to transcribe
start_time = time.time()

#use OpenAI function transcriptions.create to perform the transcription
with open(audio_file_path, "rb") as audio_file:
    transcript = openai.audio.transcriptions.create(
        model="whisper-1",
        file=audio_file,
        response_format="text",  # Options: "text", "json", "srt", "verbose_json"
        #prompt="This is a song" #Add prompts to help OpenAI, commented out since not always 
     helpful 
    )

#Calculate the elapsed time that the transcription took
end_time = time.time()
elapsed_time = end_time - start_time

#Print the transcript and elapsed time
print(transcript)
print(f"\n Transcription took {elapsed_time:.2f} seconds.")

