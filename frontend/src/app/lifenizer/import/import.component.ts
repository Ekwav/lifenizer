import { Component, OnInit, Inject, EventEmitter } from '@angular/core';
import { NgxFileUploadRequest, NgxFileUploadStorage, NgxFileUploadFactory, NgxFileUploadOptions } from '@ngx-file-upload/core';

import { UploadOutput, UploadInput, UploadFile, humanizeBytes, UploaderOptions, UploadStatus } from '@angular-ex/uploader';

@Component({
  selector: 'app-import',
  templateUrl: './import.component.html',
  styleUrls: ['import.component.scss']
})
export class ImportComponent {

  url = 'http://localhost:5000/api/upload/';

  token = "my nice token";
  formData: FormData;
  files: UploadFile[];
  uploadInput: EventEmitter<UploadInput>;
  humanizeBytes: Function;
  dragOver: boolean;
  options: UploaderOptions;

  converter : string = "png";

  constructor() {
    this.options = { concurrency: 2, maxUploads: 30, maxFileSize: 1000000000 };
    this.files = [];
    this.uploadInput = new EventEmitter<UploadInput>();
    this.humanizeBytes = humanizeBytes;
  }

  onUploadOutput(output: UploadOutput): void {
    console.log(output);
    if (output.type === 'allAddedToQueue') {
      const event: UploadInput = {
        type: 'uploadAll',
        url: this.url + this.converter,
        method: 'POST',
        data: { foo: 'bar' },
        headers: { Authorization: `bearer ${this.token}`,Kevin:"no" }
      };

      this.uploadInput.emit(event);
    } else if (output.type === 'addedToQueue' && typeof output.file !== 'undefined') {
      this.files.push(output.file);
    } else if (output.type === 'uploading' && typeof output.file !== 'undefined') {
      const index = this.files.findIndex(file => typeof output.file !== 'undefined' && file.id === output.file.id);
      this.files[index] = output.file;
    } else if (output.type === 'cancelled' || output.type === 'removed') {
      this.files = this.files.filter((file: UploadFile) => file !== output.file);
    } else if (output.type === 'dragOver') {
      this.dragOver = true;
    } else if (output.type === 'dragOut') {
      this.dragOver = false;
    } else if (output.type === 'drop') {
      this.dragOver = false;
    } else if (output.type === 'rejected' && typeof output.file !== 'undefined') {
      console.log(output.file.name + ' rejected');
    }

    this.files = this.files.filter(file => file.progress.status !== UploadStatus.Done);
  }

  cancelUpload(id: string): void {
    this.uploadInput.emit({ type: 'cancel', id: id });
  }

  removeFile(id: string): void {
    this.uploadInput.emit({ type: 'remove', id: id });
  }

  removeAllFiles(): void {
    this.uploadInput.emit({ type: 'removeAll' });
  }


  public onSelect(event) {
    const addedFiles: File[] = event.addedFiles;
    console.log(addedFiles);
    // upload
  }
   
  public onRemove(upload: NgxFileUploadRequest) {
    console.log(upload);
    // remove
  }
}
