# Image File Conversion Powershell 7 script collection
A set of claude-vibed, lightly beginner hand touched powershell 7 scripts for automated batch conversion into modern image formats; namely JPEG-XL, WebP and Avif. Pulled from free AI usage miles of Claude mostly, real world tested under Windows 11 + Powershell 7. This git is here only in case I personally misplace these scripts, or someone else has the same needs for batch conversion with more defined parameters, and does stumbles their way here instead of redoing the work. I am no coder, hand fixing or improving these scripts went out of the window pretty fast as their relative complexity rose. But they are tested functional without unwanted quirks, bugs or oversights. Do whatever you wish with these. I do not like AI personally so much so I would feel pride in what I have not done here and claim some ownership over the results from sentences prompted and free tokens used. That's about it. 

Assumptions:   
Platform: Windows 10 or Windows 11   
Powershell 7 installation and default usage over system installed pwsh core.   
Windows Terminal, though there is likely no difference in functionality with basic windows command line window.    
*the scripts should be in theory mostly compatible with Linux systems that have Powershell 7 installed, but no testing has been done with any Linux distro plus Powershell 7 at this time. Plus, Linux platform would likely benefit more from a well built shell batch script instead.*  

Prerequisites:   
JPEG-XL handling and JXL focused scripts: [Binaries of libjxl](https://github.com/libjxl/libjxl).  
JPEGLI related handling and scripts: [jpegli tools](https://github.com/google/jpegli). Google does not provide builds, so you have to bring your own msys/visual studio install and let them rip.   
WebP handling: [libwebp/webp codec binaries](https://github.com/webmproject/libwebp). Google does not have prebuilt releases so you have to fire up visual studio and build it yourself.   
Avif handling: [Avif encoder and decoder binaries](https://github.com/AOMediaCodec/libavif). Luckily, builds are provided in releases of this project.   
Additionally; For animated webp and animalted avif scripts, [FFMPEG](https://github.com/FFmpeg/FFmpeg) binaries are required.     

*Under the legal ambiguity, I do not provide builds. The tools and their requisite libraries should be in a directory exposed to %PATH%. Usage of these scripts is also made easier by placing them in a directory exposed to %PATH%. I personally have a C:\bin\ directory for this purpose.*      


#### General usage:   
These scripts are meant for command line usage. The requisite encoder/decoder binaries and these scripts should be in directory added to %PATH%. I personally use C:\bin\. These scripts have my subjective "Generally visually lossless / high quality" defaults, and no clean up behavior by default. Running a script alone from with image file filled target will end up with both original and new images next to each other in a directory. These scripts may be very compatible with OneCommander's implementation of automation scripts, this is untested.   
The scripts come with pretty OK help sections pulled up with a -h.   
Most if not all scripts have some universal switches:   
"-del" for "deletion": This function actually deletes the larger file after conversion, into the recycle bin in Windows. The assumed use case is to compress collections into selected format so the smaller file wins out with this switch. There is no real user exposed way to override this behavior. Instead, one could output the files into a sub folder, and then delete the originals if results are satisfactory.   
"-dir" for "directory": Usage "examplebatcher.ps1 -dir ohio". This will output all conversion results into sub folder named "ohio". Otherwise, the conversion results are output in the same directory with the source file.    
"-r" for "recursive": Recursively searches for files. Output is conversion target's directory, not exclusively the directory script command is ran from. -dir in tandem with -r also spawns the sub folders next to converted files, i.e. "maindir/subdir/ohio/results.jxl".   

#### Other stuff:   
If you would rather have a nifty gooey for this under windows or linux, [XL-Converter](https://github.com/JacobDev1/xl-converter) is your best bet. These scripts were "would-you-kindlyied" to utilize latest code/release of these codecs with more variable quality target such as defaulting to use "Distance" in CJPEGLI or CJXL instead of the JPEG quality scale.    

##### Quirky additive file name suffixes from few scripts:    
My JXL handling script especially, but for lossless also avif and webp handlers will add to the file names depending on target conversion. Even/especially the competitive modes available. This stems from my go-to image viewers being unable to tell to me crucial encoding info by themselves. So I've personally elected to use addon suffixes for my personal tracking.  
Lossless files get .ll addition. "**L**oss**L**ess". This can apply to all image formats here as all of them have an optional lossless mode.   
JXL Lossy Modular encodes wll get .md.jxl. "**M**o**D**ular". Using Affinity and JXL files, modular lossy files have color reproduction inaccuracies with Affinity Photo. Bandaid is to be aware of modular lossy files and temporary convert them to PNG for manipulation.   
".jpg.jxl" For lossless JPG recompression files. Makes it easier to track these files from other types of JXL files. Main reasoning being if you ever need to extract the original JPEG for compatibility.    

#### Related, Unrelated scripts added to collection:   
**Recyclio.ps1** is an anomalous addition with the rest. It is only a simple script that asks user for time interval of 5, 10 or 15 minutes, and clears windows recycle bin with that interval. Personal use case is running one or several of these scripts with -del switch and having something automate the recycle bin emptying. This is entirely superficially cautious workflow enabler that I want to do instead of straight deletion in the scripts so I have possibility to undo errors. And you can too if you are in the same metaphorical thought boat.

**file_folder_demomo.ps1**     
***BE VERY CAREFUL WITH THIS SCRIPT. NO -HELP. NO CONFIRMATION ASKED. RUN IT AND IT SHALL GO!***   
But what will it do? This is another personal script meant for image file sub folder  jungle situations that one might want to compress into the main folder. It will target the directory the script is run from as the main directory, recursively move all files to the main directory from all nested sub directories and adds the the directory names to file's name with separators.    
**Example:** mainfolder/images/2016/08/photo004.jpg -> mainfolder/images_2016_08_photo004.jpg   
No pruning logic either, just use your explorer and del key like in the olden days. Really, Bulk Rename Utility does the same slower but safer with a undo.   
