import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ImportComponent } from './import/import.component';
import { NgxFileUploadCoreModule } from "@ngx-file-upload/core";
import { Routes, RouterModule } from '@angular/router';
import { NgxDropzoneModule } from 'ngx-dropzone';
import { SearchFieldModule } from 'ngx-mat-search-field';
import { SearchComponent } from './search/search.component';
import { MatFormFieldModule } from '@angular/material/form-field';
import { NgxUploaderModule } from 'ngx-uploader';

const routes: Routes = [
  {path:"import",component:ImportComponent},
  {path:"search",component:SearchComponent}

];

@NgModule({
  declarations: [ImportComponent, SearchComponent],
  imports: [
    RouterModule.forChild(routes),
    CommonModule,
    NgxDropzoneModule,
    NgxFileUploadCoreModule,
    MatFormFieldModule,
    SearchFieldModule,

    NgxUploaderModule
  ]
})
export class LifenizerModule { }
