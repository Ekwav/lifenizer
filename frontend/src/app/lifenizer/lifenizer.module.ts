import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ImportComponent } from './import/import.component';
import { NgxFileUploadCoreModule } from "@ngx-file-upload/core";
import { Routes, RouterModule } from '@angular/router';
import { NgxDropzoneModule } from 'ngx-dropzone';
import { SearchComponent } from './search/search.component';
import { MatFormFieldModule } from '@angular/material/form-field';
import { NgxUploaderModule } from 'ngx-uploader';
import { MatToolbarModule } from '@angular/material/toolbar';
import { MatInputModule } from '@angular/material/input';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { HttpClientModule } from '@angular/common/http';
import { JwtModule, JWT_OPTIONS } from '@auth0/angular-jwt';
import { AuthService } from './auth.service';
import { ReactiveFormsModule } from '@angular/forms';

const routes: Routes = [
  {path:"import",component:ImportComponent},
  {path:"search",component:SearchComponent}

];

export function tokenGetter() {
  return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiJlZmVjOTEzYS04NWY3LTRmZWUtODdiMi1iOWExOGRkOTI5YjUiLCJ2YWxpZCI6IjEiLCJ1c2VyaWQiOiIxIiwibmFtZSI6ImJpbGFsIiwiZXhwIjoxNjE1NTAzMTQxLCJpc3MiOiJodHRwOi8vbXlzaXRlLmNvbSIsImF1ZCI6Imh0dHA6Ly9teXNpdGUuY29tIn0.CiibjEKeX-qDVEYlrIlxngz8_nalCLFw5rkaK9XJi-Y";// localStorage.getItem("access_token");
}

export function jwtOptionsFactory(authService : AuthService) {
  return {
    tokenGetter: () => {
      return authService.getAsyncToken();
    },
    allowedDomains: ["localhost:5001","localhost:5000","coflnet.com"],
    disallowedRoutes: ["https://localhost:5001/auth/gettoken"],
  }
}

@NgModule({
  declarations: [ImportComponent, SearchComponent],
  imports: [
    RouterModule.forChild(routes),
    CommonModule,
    NgxDropzoneModule,
    NgxFileUploadCoreModule,
    MatFormFieldModule,
    NgxUploaderModule,
    ReactiveFormsModule,
    MatInputModule,
    MatIconModule,
    MatButtonModule,
    MatAutocompleteModule,
    HttpClientModule,
    JwtModule.forRoot({
      jwtOptionsProvider: {
        provide: JWT_OPTIONS,
        useFactory: jwtOptionsFactory,
        deps: [AuthService]
      }
    }),
  ]
})
export class LifenizerModule { }
