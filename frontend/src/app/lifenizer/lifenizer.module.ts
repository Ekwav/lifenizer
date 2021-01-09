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
import {MatToolbarModule} from '@angular/material/toolbar';
import { HttpClientModule } from '@angular/common/http';
import { JwtModule } from '@auth0/angular-jwt';

const routes: Routes = [
  {path:"import",component:ImportComponent},
  {path:"search",component:SearchComponent}

];

export function tokenGetter() {
  return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiI1MzY2MGYyMi0xZWZjLTQxMmEtOTNjNy1lOTUzNDRmY2MxYmYiLCJ2YWxpZCI6IjEiLCJ1c2VyaWQiOiIxIiwibmFtZSI6ImJpbGFsIiwiZXhwIjoxNjAzMTM2Mjg3LCJpc3MiOiJodHRwOi8vbXlzaXRlLmNvbSIsImF1ZCI6Imh0dHA6Ly9teXNpdGUuY29tIn0.KT61cPsjv9bB5jnM4pz8TfeOd9RPimIxjaKVkOG2syo";// localStorage.getItem("access_token");
}

@NgModule({
  declarations: [ImportComponent, SearchComponent],
  imports: [
    RouterModule.forChild(routes),
    CommonModule,
    NgxDropzoneModule,
    NgxFileUploadCoreModule,
    MatFormFieldModule,
    SearchFieldModule,

    NgxUploaderModule,
    HttpClientModule,
    JwtModule.forRoot({
      config: {

        tokenGetter: tokenGetter,
        allowedDomains: ["localhost:5001","localhost:5000","coflnet.com"],
        disallowedRoutes: ["http://example.com/examplebadroute/"],
      },
    }),
  ]
})
export class LifenizerModule { }
